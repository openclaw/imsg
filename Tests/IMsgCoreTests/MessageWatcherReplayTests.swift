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

@Test(.timeLimit(.minutes(1)))
func messageWatcherRetainsPreviewsAcrossUnresolvedChatRetry() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  for (offset, text) in [
    "https://example.com/first", "unresolved", "https://example.com/later",
    "https://example.com/first", "done",
  ].enumerated() {
    let rowID = Int64(offset + 1)
    try insertURLPreviewTestMessage(
      db, rowID: rowID, text: text, guid: "message-\(rowID)",
      balloonBundleID: text.hasPrefix("https:") ? MessageStore.urlPreviewBalloonBundleID : nil,
      date: now.addingTimeInterval(Double(offset))
    )
  }
  try db.run("DELETE FROM chat_message_join WHERE message_id = 2")
  let store = try MessageStore(connection: db, path: ":memory:")
  let polls = WatcherPollController()
  defer { polls.releaseAll() }
  let firstPoll = polls.pauseNextPoll()
  let stream = MessageWatcher(store: store, didPoll: polls.didPoll).stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0, fallbackPollInterval: nil, batchLimit: 10
    )
  )
  await polls.waitUntilPaused(firstPoll)
  _ = try store.withConnection { connection in
    try connection.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  }
  polls.release(firstPoll)

  var received: [Int64] = []
  for try await message in stream {
    received.append(message.rowID)
    if message.rowID == 5 { break }
  }
  #expect(received == [1, 2, 3, 5])
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherDrainsReplayWithoutFallbackOrFileEvents() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  for rowID in 1...3 {
    try fixture.insertMessage(Int64(rowID), "message-\(rowID)")
  }
  let stream = MessageWatcher(store: fixture.store).stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0, fallbackPollInterval: nil, batchLimit: 1
    )
  )
  let received = try await withThrowingTaskGroup(of: [Message].self) { group in
    group.addTask { try await firstReplayMessages(3, from: stream) }
    group.addTask {
      try await Task.sleep(for: .seconds(3))
      return []
    }
    let messages = try await group.next() ?? []
    group.cancelAll()
    return messages
  }
  #expect(received.map(\.rowID) == [1, 2, 3])
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
  let previewBatch = try store.messagesAfterBatch(
    afterRowID: 1,
    chatID: 1,
    limit: 1,
    includeReactions: false
  )
  #expect(previewBatch.messages.isEmpty)
  #expect(previewBatch.maxScannedRowID == 2)

  let nextBatch = try store.messagesAfterBatch(
    afterRowID: previewBatch.maxScannedRowID,
    chatID: 1,
    limit: 1,
    includeReactions: false
  )
  #expect(nextBatch.messages.map(\.rowID) == [3])
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherPreservesShippedCursorSemantics() async throws {
  for cursor in [Int64?.none, Int64?.some(0)] {
    let fixture = try WatcherTestDatabase.makeMutableStore()
    try fixture.insertMessage(1, "existing")
    let polls = WatcherPollController()
    let stream = MessageWatcher(store: fixture.store, didPoll: polls.didPoll).stream(
      sinceRowID: cursor,
      configuration: MessageWatcherConfiguration(
        debounceInterval: 0,
        fallbackPollInterval: 0.01,
        batchLimit: 10
      )
    )
    let nextMessage = Task { try await firstReplayMessages(1, from: stream) }

    await polls.waitForPoll(1)
    try fixture.insertMessage(2, "new")
    let messages = try await nextMessage.value
    #expect(messages.map(\.rowID) == [2])
  }

  let fixture = try WatcherTestDatabase.makeMutableStore()
  try fixture.insertMessage(1, "existing")
  let replay = MessageWatcher(store: fixture.store).stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10
    )
  )
  let replayedMessages = try await firstReplayMessages(1, from: replay)
  #expect(replayedMessages.map(\.rowID) == [1])
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
    sinceRowID: -1,
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
    sinceRowID: -1,
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
