import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesAfterCoalescesGUIDLinkedURLPreviewWhenTextOmitsURL() throws {
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
    replyToGUID: "p:0/text-guid",
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
func messagesAfterKeepsUnlinkedURLPreviewWhenTextOmitsURL() throws {
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
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(0.206)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1, 2])
  #expect(messages.allSatisfy { $0.urlPreview == nil })
}

@Test
func messagesAfterCoalescesGUIDLinkedPreviewWithoutReactionColumns() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeGUID: true,
      includeBalloonBundleID: true,
      includeReplyToGUID: true
    )
  )
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, reply_to_guid, balloon_bundle_id,
      date, is_from_me, service
    )
    VALUES
      (1, 1, 'Check this out', 'text-guid', NULL, NULL, ?, 0, 'iMessage'),
      (2, 1, 'https://example.com', 'preview-guid', 'text-guid', ?, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(0.399))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.urlPreview?.rowID == 2)
}

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
func searchMessagesByExactURLCoalescesGUIDLinkedPreviewWhenTextOmitsURL() throws {
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
  let messages = try store.searchMessages(
    query: "https://example.com",
    match: "exact",
    limit: 10
  )

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
