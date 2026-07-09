import Foundation
import SQLite
import Testing

@testable import IMsgCore

func makeURLPreviewTestDB() throws -> Connection {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      guid TEXT,
      associated_message_guid TEXT,
      associated_message_type INTEGER,
      balloon_bundle_id TEXT,
      is_read INTEGER, date_read INTEGER,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
  return db
}

func insertURLPreviewTestMessage(
  _ db: Connection,
  rowID: Int64,
  chatID: Int64 = 1,
  handleID: Int64 = 1,
  text: String,
  guid: String,
  associatedMessageGUID: String? = nil,
  associatedMessageType: Int? = nil,
  balloonBundleID: String? = nil,
  date: Date,
  isFromMe: Bool = false,
  isRead: Bool = false,
  dateRead: Date? = nil
) throws {
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, is_read, date_read, date, is_from_me, service
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'iMessage')
    """,
    rowID,
    handleID,
    text,
    guid,
    associatedMessageGUID,
    associatedMessageType,
    balloonBundleID,
    isRead ? 1 : 0,
    dateRead.map(TestDatabase.appleEpoch) ?? 0,
    TestDatabase.appleEpoch(date),
    isFromMe ? 1 : 0
  )
  try db.run(
    "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)",
    chatID,
    rowID
  )
}

@Test
func messagesAfterSkipsPreviewOnlyBatchForPublicCursorlessAPI() throws {
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
  let messages = try store.messagesAfter(afterRowID: 1, chatID: 1, limit: 1)

  #expect(messages.map(\.rowID) == [3])
}

@Test
func messagesByChatCoalescesURLPreviewSplitSend() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  let readAt = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now,
    isRead: true,
    dateRead: readAt
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
  let messages = try store.messages(chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.guid == "text-guid")
  #expect(messages.first?.text == "Dump https://example.com")
  #expect(messages.first?.balloonBundleID == nil)
  #expect(messages.first?.urlPreview?.rowID == 2)
  #expect(messages.first?.urlPreview?.guid == "preview-guid")
  #expect(messages.first?.urlPreview?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
  #expect(messages.first?.isRead == true)
  #expect(messages.first?.dateRead == readAt)
}

@Test
func messagesByChatUsesRowOrderForURLPreviewPredecessor() throws {
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
    rowID: 3,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 4,
    text: "timestamp between text and preview, inserted after preview",
    guid: "late-row-guid",
    date: now.addingTimeInterval(0.5)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [4, 1])
  #expect(messages.last?.urlPreview?.rowID == 3)
}

@Test
func messagesAfterCoalescesPreviewPastReactionCandidate() throws {
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
    text: "Loved https://example.com",
    guid: "reaction-guid",
    associatedMessageGUID: "text-guid",
    associatedMessageType: 2000,
    date: now.addingTimeInterval(0.5)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(
    afterRowID: 0,
    chatID: 1,
    limit: 10,
    includeReactions: true
  )

  #expect(messages.map(\.rowID) == [1, 2])
  #expect(messages.first?.urlPreview?.rowID == 3)
  #expect(messages.last?.isReaction == true)
}

@Test
func messagesAfterCoalescesURLPreviewSplitSend() throws {
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
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.urlPreview?.rowID == 2)
}

func messagesAfterSuppressesLateURLPreviewWhenTextWasAlreadySeen() throws {
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
  let messages = try store.messagesAfter(afterRowID: 1, chatID: 1, limit: 10)

  #expect(messages.isEmpty)
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

@Test
func searchMessagesCoalescesURLPreviewSplitSend() throws {
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
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.urlPreview?.guid == "preview-guid")
}

@Test
func exactSearchDoesNotReplaceMatchingPreviewWithNonmatchingText() throws {
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
  let messages = try store.searchMessages(query: "https://example.com", match: "exact", limit: 10)

  #expect(messages.map(\.rowID) == [2])
  #expect(messages.first?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
}

@Test
func historyDateFilterDoesNotReplacePreviewWithFilteredOutText() throws {
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
  let filter = MessageFilter(startDate: now.addingTimeInterval(0.5))
  let messages = try store.messages(chatID: 1, limit: 10, filter: filter)

  #expect(messages.map(\.rowID) == [2])
  #expect(messages.first?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
}

@Test
func searchCoalescingRequiresActualPreviousChatRow() throws {
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
    text: "intervening",
    guid: "middle-guid",
    date: now.addingTimeInterval(0.5)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "example.com", match: "contains", limit: 10)

  #expect(messages.map(\.rowID) == [3, 1])
  #expect(messages.first?.balloonBundleID == MessageStore.urlPreviewBalloonBundleID)
  #expect(messages.last?.urlPreview == nil)
}

@Test
func nonURLBalloonMessagesAreNotCoalesced() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Poll https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "poll-guid",
    balloonBundleID: MessagePollDecoder.pollsBundleIdentifier,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1, 2])
  #expect(messages[1].balloonBundleID == MessagePollDecoder.pollsBundleIdentifier)
}

@Test
func separateSameSenderTextMessagesAreNotCoalesced() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "first-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "second-guid",
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1, 2])
  #expect(messages.allSatisfy { $0.urlPreview == nil })
}
