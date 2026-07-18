import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageWatcherKeepsUnlinkedLiveURLPreviewSeparateWhileSettling() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.05,
      batchLimit: 10
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "first message",
      guid: "text-guid",
      date: now
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "https://example.com",
      guid: "unlinked-preview-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview == nil)
  #expect(second?.rowID == 2)
  #expect(second?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
  #expect(third == nil)
}

@Test
func messageWatcherDoesNotExtendOlderSettleDeadlineForNewerLiveText() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.1,
      batchLimit: 10
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "plain first",
      guid: "first-guid",
      date: now
    )
  }
  try await Task.sleep(nanoseconds: 70_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "Check this out",
      guid: "second-guid",
      date: now.addingTimeInterval(0.5)
    )
  }

  let first = try await nextMessage(from: stream, timeoutNanoseconds: 70_000_000)

  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 3,
      text: "https://example.com",
      guid: "preview-guid",
      replyToGUID: "second-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }

  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(second?.rowID == 2)
  #expect(second?.urlPreview?.rowID == 3)
  #expect(third == nil)
}

@Test
func messageWatcherDoesNotRestartSettleDeadlineAcrossLimitedPages() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.1,
      batchLimit: 1
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    for rowID in Int64(1)...4 {
      try insertURLPreviewTestMessage(
        connection,
        rowID: rowID,
        text: "message \(rowID)",
        guid: "guid-\(rowID)",
        date: now.addingTimeInterval(Double(rowID))
      )
    }
  }

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 70_000_000)
  let fourth = try await nextMessage(from: stream)

  #expect([first?.rowID, second?.rowID, third?.rowID, fourth?.rowID] == [1, 2, 3, 4])
}

@Test
func watcherTailQueryExcludesReactionsWhenConfigured() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "message",
    guid: "message-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "Loved message",
    guid: "reaction-guid",
    associatedMessageGUID: "message-guid",
    associatedMessageType: 2001,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(try store.maxRowID(chatID: 1, includeReactions: false) == 1)
  #expect(try store.maxRowID(chatID: 1, includeReactions: true) == 2)
  #expect(try store.maxRowID(chatID: nil, includeReactions: false) == 1)
  #expect(try store.maxRowID(chatID: nil, includeReactions: true) == 2)
}

@Test
func messageWatcherDoesNotSettleReactionEvents() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let stream = MessageWatcher(store: store).stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.2,
      batchLimit: 10,
      includeReactions: true
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "Loved message",
      guid: "reaction-guid",
      associatedMessageGUID: "target-guid",
      associatedMessageType: 2001,
      date: now
    )
  }

  let reaction = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)
  #expect(reaction?.rowID == 1)
  #expect(reaction?.isReaction == true)
}

@Test
func messageWatcherKeepsReactionBehindEarlierSettleGap() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let stream = MessageWatcher(store: store).stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.05,
      batchLimit: 10,
      includeReactions: true
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "plain text",
      guid: "text-guid",
      date: now
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "Loved message",
      guid: "reaction-guid",
      associatedMessageGUID: "text-guid",
      associatedMessageType: 2001,
      date: now.addingTimeInterval(0.01)
    )
  }

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(second?.rowID == 2)
  #expect(second?.isReaction == true)
  #expect(third == nil)
}
