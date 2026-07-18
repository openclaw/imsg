import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageWatcherCoalescesGUIDLinkedURLPreviewAcrossBatchBoundary() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Check this out",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "preview-guid",
    replyToGUID: "text-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      fallbackPollInterval: nil,
      batchLimit: 1
    )
  )

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview?.rowID == 2)
  #expect(first?.text == "Check this out\nhttps://example.com")
  #expect(second == nil)
}

@Test
func messageWatcherCoalescesLivePreviewPastInterleavedChatRow() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: 0.005,
      urlPreviewSettleInterval: 0.05,
      batchLimit: 1
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      chatID: 1,
      text: "Check this out",
      guid: "text-guid",
      date: now
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      chatID: 2,
      text: "other chat",
      guid: "other-guid",
      date: now.addingTimeInterval(0.5)
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 3,
      chatID: 1,
      text: "https://example.com",
      guid: "preview-guid",
      replyToGUID: "text-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview?.rowID == 3)
  #expect(first?.text == "Check this out\nhttps://example.com")
  #expect(second?.rowID == 2)
  #expect(third == nil)
}

@Test
func messageWatcherDoesNotSkipRowsBeforeLookedAheadPreview() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      chatID: 1,
      text: "Check this out",
      guid: "text-guid",
      date: now
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      chatID: 2,
      text: "first interleaved",
      guid: "first-interleaved-guid",
      date: now.addingTimeInterval(0.25)
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 3,
      chatID: 2,
      text: "second interleaved",
      guid: "second-interleaved-guid",
      date: now.addingTimeInterval(0.5)
    )
    try insertURLPreviewTestMessage(
      connection,
      rowID: 4,
      chatID: 1,
      text: "https://example.com",
      guid: "preview-guid",
      replyToGUID: "text-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }

  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: nil,
      urlPreviewSettleInterval: 1,
      batchLimit: 1
    )
  )

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream)
  let third = try await nextMessage(from: stream)
  let fourth = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview?.rowID == 4)
  #expect(second?.rowID == 2)
  #expect(third?.rowID == 3)
  #expect(fourth == nil)
}

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
func messageWatcherCoalescesURLContainingTextAcrossBatchBoundary() async throws {
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

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      fallbackPollInterval: nil,
      batchLimit: 1
    )
  )

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview?.rowID == 2)
  #expect(second == nil)
}

@Test
func messageWatcherCoalescesBacklogPreviewPastInterleavedChatRow() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    chatID: 1,
    text: "Check this out",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    chatID: 2,
    text: "other chat",
    guid: "other-guid",
    date: now.addingTimeInterval(0.5)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 4,
    chatID: 1,
    text: "https://example.com",
    guid: "preview-guid",
    replyToGUID: "text-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: 1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.005,
      fallbackPollInterval: nil,
      urlPreviewSettleInterval: 1,
      batchLimit: 1
    )
  )

  let first = try await nextMessage(from: stream, timeoutNanoseconds: 200_000_000)
  let second = try await nextMessage(from: stream, timeoutNanoseconds: 200_000_000)
  let third = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 2)
  #expect(first?.urlPreview?.rowID == 4)
  #expect(first?.text == "Check this out\nhttps://example.com")
  #expect(second?.rowID == 3)
  #expect(third == nil)
}

@Test
func messageWatcherCoalescesGUIDLinkedURLPreviewInsertedAfterTextRow() async throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  let store = try MessageStore(connection: db, path: ":memory:")
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: 1,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      fallbackPollInterval: 0.01,
      urlPreviewSettleInterval: 2,
      batchLimit: 10
    )
  )

  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "Check this out",
      guid: "text-guid",
      date: now
    )
  }
  try await Task.sleep(nanoseconds: 30_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "https://example.com",
      guid: "preview-guid",
      replyToGUID: "text-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(1)
    )
  }

  let first = try await nextMessage(from: stream)
  let second = try await nextMessage(from: stream, timeoutNanoseconds: 100_000_000)

  #expect(first?.rowID == 1)
  #expect(first?.urlPreview?.rowID == 2)
  #expect(first?.text == "Check this out\nhttps://example.com")
  #expect(second == nil)
}

@Test
func messageWatcherEmitsLateURLPreviewInsteadOfDroppingItsURL() async throws {
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
      urlPreviewSettleInterval: 0.02,
      batchLimit: 10
    )
  )

  try await Task.sleep(nanoseconds: 10_000_000)
  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 1,
      text: "Check this out",
      guid: "text-guid",
      date: now
    )
  }
  let first = try await nextMessage(from: stream)

  _ = try store.withConnection { connection in
    try insertURLPreviewTestMessage(
      connection,
      rowID: 2,
      text: "https://example.com",
      guid: "preview-guid",
      replyToGUID: "text-guid",
      balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
      date: now.addingTimeInterval(3)
    )
  }
  let second = try await nextMessage(from: stream)

  #expect(first?.rowID == 1)
  #expect(first?.text == "Check this out")
  #expect(second?.rowID == 2)
  #expect(second?.text == "https://example.com")
  #expect(second?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
}
