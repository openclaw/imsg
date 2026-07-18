import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesAfterCoalescesAssociatedGUIDLinkedURLPreviewWhenTextOmitsURL() throws {
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
    associatedMessageGUID: "p:0/text-guid",
    associatedMessageType: 0,
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(0.399)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.text == "Check this out\nhttps://example.com")
  #expect(messages.first?.urlPreview?.rowID == 2)
}

@Test
func searchMessagesByURLCoalescesGUIDLinkedPreviewWhenTextOmitsURL() throws {
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
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.text == "Check this out\nhttps://example.com")
  #expect(messages.first?.urlPreview?.rowID == 2)
}

@Test
func searchMessagesByCaptionIncludesGUIDLinkedPreviewWhenTextOmitsURL() throws {
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
  let messages = try store.searchMessages(query: "Check this", match: "contains", limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.text == "Check this out\nhttps://example.com")
  #expect(messages.first?.urlPreview?.rowID == 2)
}

@Test
func messagesAfterKeepsLimitWhenPreviewLookaheadCrossesInterleavedRows() throws {
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
    chatID: 2,
    text: "interleaved",
    guid: "interleaved-guid",
    date: now.addingTimeInterval(0.5)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "https://example.com",
    guid: "preview-guid",
    replyToGUID: "text-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 1)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.urlPreview?.rowID == 3)
}
