import Foundation
import SQLite
import Testing

@testable import IMsgCore

private func firstReplayMessages(
  _ count: Int,
  from stream: AsyncThrowingStream<Message, Error>
) async throws -> [Message] {
  var iterator = stream.makeAsyncIterator()
  var messages: [Message] = []
  while messages.count < count, let message = try await iterator.next() {
    messages.append(message)
  }
  return messages
}

@Test
func messagesAfterBatchAdvancesAcrossSuppressedLateURLPreview() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "after",
    guid: "after-guid",
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  var dedupeState = URLBalloonDedupeState()
  let previewBatch = try store.messagesAfterBatch(
    afterRowID: 1,
    chatID: 1,
    limit: 1,
    includeReactions: false,
    dedupeState: &dedupeState
  )
  #expect(previewBatch.messages.isEmpty)
  #expect(previewBatch.maxScannedRowID == 2)

  let nextBatch = try store.messagesAfterBatch(
    afterRowID: previewBatch.maxScannedRowID,
    chatID: 1,
    limit: 1,
    includeReactions: false,
    dedupeState: &dedupeState
  )
  #expect(nextBatch.messages.map(\.rowID) == [3])
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherDistinguishesOmittedCursorFromExplicitZero() async throws {
  let currentFixture = try WatcherTestDatabase.makeMutableStore()
  try currentFixture.insertMessage(1, "existing")
  let currentPolls = WatcherPollController()
  let currentWatcher = MessageWatcher(store: currentFixture.store, didPoll: currentPolls.didPoll)
  let currentStream = currentWatcher.stream(
    sinceRowID: nil,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: 0.01,
      batchLimit: 10
    )
  )
  let currentTask = Task { try await firstReplayMessages(1, from: currentStream) }

  await currentPolls.waitForPoll(1)
  try currentFixture.insertMessage(2, "new")
  let currentMessages = try await currentTask.value
  #expect(currentMessages.map(\.rowID) == [2])

  let replayFixture = try WatcherTestDatabase.makeMutableStore()
  try replayFixture.insertMessage(1, "first")
  try replayFixture.insertMessage(2, "second")
  let zeroReplayStream = MessageWatcher(store: replayFixture.store).stream(
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10
    )
  )
  let negativeReplayStream = MessageWatcher(store: replayFixture.store).stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10
    )
  )
  let zeroReplayMessages = try await firstReplayMessages(2, from: zeroReplayStream)
  let negativeReplayMessages = try await firstReplayMessages(2, from: negativeReplayStream)
  #expect(zeroReplayMessages.map(\.rowID) == [1, 2])
  #expect(negativeReplayMessages.map(\.rowID) == zeroReplayMessages.map(\.rowID))
}

@Test(.timeLimit(.minutes(1)))
func messageWatchersOwnIndependentURLDedupeAcrossOverflow() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "https://example.com",
    guid: "preview-one",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "two",
    guid: "message-two",
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "three",
    guid: "message-three",
    date: now.addingTimeInterval(2)
  )
  let store = try MessageStore(connection: db, path: ":memory:")
  let firstPolls = WatcherPollController()
  defer { firstPolls.releaseAll() }
  let pausedFirstPoll = firstPolls.pauseNextPoll()
  let firstStream = MessageWatcher(store: store, didPoll: firstPolls.didPoll).stream(
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10,
      bufferLimit: 1
    )
  )
  await firstPolls.waitUntilPaused(pausedFirstPoll)

  let secondPoll = WatcherPollSignal()
  let secondStream = MessageWatcher(store: store) {
    Task { await secondPoll.signal() }
  }.stream(
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10,
      bufferLimit: 1
    )
  )
  await secondPoll.wait()
  firstPolls.release(pausedFirstPoll)

  let first = await drainWatcher(firstStream)
  let second = await drainWatcher(secondStream)
  #expect(first.messages.map(\.rowID) == [1])
  #expect(second.messages.map(\.rowID) == [1])
  #expect(first.error is MessageWatcherOverflowError)
  #expect(second.error is MessageWatcherOverflowError)
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherCoalescesURLPreviewSplitAcrossPolls() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  let store = try MessageStore(connection: db, path: ":memory:")
  let polls = WatcherPollController()
  defer { polls.releaseAll() }
  let firstPoll = polls.pauseNextPoll()
  let stream = MessageWatcher(store: store, didPoll: polls.didPoll).stream(
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: 0.001,
      batchLimit: 10
    )
  )
  let messages = Task { try await firstReplayMessages(2, from: stream) }

  await polls.waitUntilPaused(firstPoll)
  try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "See https://example.com",
      guid: "text",
      date: now
    )
  }
  let textPoll = polls.pauseNextPoll()
  polls.release(firstPoll)

  await polls.waitUntilPaused(textPoll)
  try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "https://example.com",
      guid: "preview",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }
  let previewPoll = polls.pauseNextPoll()
  polls.release(textPoll)

  await polls.waitUntilPaused(previewPoll)
  try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 3,
      text: "after",
      guid: "after",
      date: now.addingTimeInterval(2)
    )
  }
  polls.release(previewPoll)

  let received = try await messages.value
  #expect(received.map(\.rowID) == [1, 3])
}
