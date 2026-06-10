import Foundation
import Testing

@testable import IMsgCore

@Test
func messagesByChatFillsLogicalLimitAfterCoalescingPreview() throws {
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
    text: "older",
    guid: "older-guid",
    date: now.addingTimeInterval(-1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 2)

  #expect(messages.map(\.rowID) == [1, 3])
  #expect(messages.first?.urlPreview?.rowID == 2)
}

@Test
func messagesByChatContinuesPastFallbackReplacementLimitBoundary() throws {
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
    date: now.addingTimeInterval(4)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "newer visible",
    guid: "newer-guid",
    date: now.addingTimeInterval(3)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 4,
    text: "second visible",
    guid: "second-guid",
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 2)

  #expect(messages.map(\.rowID) == [3, 4])
}

@Test
func messagesAfterCoalescesRepeatedURLSendsBeforeDedupingStandalonePreviews() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "First https://example.com",
    guid: "first-text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "first-preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "Again https://example.com",
    guid: "second-text-guid",
    date: now.addingTimeInterval(30)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 4,
    text: "https://example.com",
    guid: "second-preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(31)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1, 3])
  #expect(messages.map { $0.urlPreview?.rowID } == [2, 4])
}

@Test
func searchMessagesFillsLogicalLimitAfterCoalescingPreview() throws {
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
    text: "older https://example.com",
    guid: "older-guid",
    date: now.addingTimeInterval(-1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 2)

  #expect(messages.map(\.rowID) == [1, 3])
  #expect(messages.first?.urlPreview?.rowID == 2)
}

@Test
func searchMessagesContinuesPastFallbackReplacementLimitBoundary() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    chatID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    chatID: 1,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(4)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    chatID: 2,
    text: "newer https://example.com",
    guid: "newer-guid",
    date: now.addingTimeInterval(3)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 4,
    chatID: 3,
    text: "second https://example.com",
    guid: "second-guid",
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 2)

  #expect(messages.map(\.rowID) == [3, 4])
}

@Test
func searchMessagesSortsReplacedPreviewByLogicalMessageDate() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    chatID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    chatID: 1,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(2)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    chatID: 2,
    text: "middle https://example.com",
    guid: "middle-guid",
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 2)

  #expect(messages.map(\.rowID) == [3, 1])
  #expect(messages.last?.urlPreview?.rowID == 2)
}
