import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func latestSentMessageMatchesNewestOutgoingTextInChat() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try insertSentMessageFixture(
    db,
    rowID: 1,
    chatID: 1,
    text: "same",
    guid: "old-guid",
    date: now.addingTimeInterval(-20),
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 2,
    chatID: 1,
    text: "same",
    guid: "incoming-guid",
    date: now.addingTimeInterval(-5),
    isFromMe: false
  )
  try insertSentMessageFixture(
    db,
    rowID: 3,
    chatID: 1,
    text: "same",
    guid: "chat-guid",
    date: now,
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 4,
    chatID: 2,
    text: "same",
    guid: "other-chat-guid",
    date: now.addingTimeInterval(5),
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: "same",
    chatID: 1,
    since: now.addingTimeInterval(-10)
  )

  #expect(message?.rowID == 3)
  #expect(message?.chatID == 1)
  #expect(message?.guid == "chat-guid")
}

@Test
func latestSentMessageFallsBackToNewestOutgoingTextWithoutChatFilter() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try insertSentMessageFixture(
    db,
    rowID: 1,
    chatID: 1,
    text: "same",
    guid: "chat-one-guid",
    date: now,
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 2,
    chatID: 2,
    text: "same",
    guid: "chat-two-guid",
    date: now.addingTimeInterval(5),
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: "same",
    chatID: nil,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 2)
  #expect(message?.chatID == 2)
  #expect(message?.guid == "chat-two-guid")
}

@Test
func latestSentMessageMatchesAttributedBodyText() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  let text = "body fallback"
  try insertAttributedSentMessageFixture(
    db,
    rowID: 10,
    chatID: 1,
    text: text,
    guid: "body-guid",
    date: now
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: text,
    chatID: 1,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 10)
  #expect(message?.guid == "body-guid")
  #expect(message?.text == text)
}

@Test
func latestSentMessagePrefersNewestDecodedAttributedBodyMatch() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  let text = "repeat"
  try insertSentMessageFixture(
    db,
    rowID: 10,
    chatID: 1,
    text: text,
    guid: "older-plain-guid",
    date: now.addingTimeInterval(-1),
    isFromMe: true
  )
  try insertAttributedSentMessageFixture(
    db,
    rowID: 11,
    chatID: 1,
    text: text,
    guid: "newer-body-guid",
    date: now
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: text,
    chatID: 1,
    since: now.addingTimeInterval(-2)
  )

  #expect(message?.rowID == 11)
  #expect(message?.guid == "newer-body-guid")
}

@Test
func latestSentMessageScansPastNewerAttributedBodyNonmatches() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  let text = "target body"
  try insertSentMessageFixture(
    db,
    rowID: 10,
    chatID: 1,
    text: "",
    attributedBody: attributedBodyFixture(text),
    guid: "target-guid",
    date: now,
    isFromMe: true
  )
  for offset in 1...55 {
    try insertSentMessageFixture(
      db,
      rowID: Int64(10 + offset),
      chatID: 1,
      text: "",
      attributedBody: attributedBodyFixture("other body \(offset)"),
      guid: "other-guid-\(offset)",
      date: now.addingTimeInterval(TimeInterval(offset)),
      isFromMe: true
    )
  }
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: text,
    chatID: 1,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 10)
  #expect(message?.guid == "target-guid")
}

@Test
func latestSentMessageMatchesDecodedAttributedBodyText() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  let text = "native root text"
  let attributedBody = attributedBodyFixture(text)
  try insertSentMessageFixture(
    db,
    rowID: 1,
    chatID: 1,
    text: "",
    attributedBody: Data([0x00]),
    guid: "newer-nonmatch",
    date: now.addingTimeInterval(1),
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 2,
    chatID: 1,
    text: "",
    attributedBody: attributedBody,
    guid: "attributed-guid",
    date: now,
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: text,
    chatID: 1,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 2)
  #expect(message?.text == text)
  #expect(message?.guid == "attributed-guid")
}

@Test
func chatInfoMatchingTargetHandlesAnyGroupPolarityMismatch() throws {
  let db = try makeSentMessageDatabase()
  try db.run(
    """
    UPDATE chat
    SET chat_identifier = 'any;+;chat134', guid = 'any;+;chat134'
    WHERE ROWID = 1
    """
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let info = try store.chatInfo(matchingTarget: "any;-;chat134")

  #expect(info?.id == 1)
  #expect(info?.guid == "any;+;chat134")
}

@Test
func latestUnjoinedSentMessageRowIDMatchesAnyGroupTargetVariants() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (2, 'any;-;chat134')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      date, is_from_me, service
    )
    VALUES (20, 2, '', 'ghost-guid', NULL, 0, ?, 1, 'SMS')
    """,
    TestDatabase.appleEpoch(now)
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let rowID = try store.latestUnjoinedSentMessageRowID(
    matchingTargetHandles: ["any;+;chat134"],
    since: now.addingTimeInterval(-1)
  )

  #expect(rowID == 20)
}

@Test
func messageSendStatusMapsFailedSentDeliveredAndPendingRows() throws {
  let db = try makeSentMessageDatabase()
  let deliveredAt = Date()
  try insertSentMessageFixture(
    db,
    rowID: 30,
    chatID: 1,
    text: "failed",
    guid: "failed-guid",
    date: deliveredAt,
    isFromMe: true,
    error: 22,
    isSent: false
  )
  try insertSentMessageFixture(
    db,
    rowID: 31,
    chatID: 1,
    text: "sent",
    guid: "sent-guid",
    date: deliveredAt,
    isFromMe: true,
    isSent: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 32,
    chatID: 1,
    text: "delivered",
    guid: "delivered-guid",
    date: deliveredAt,
    isFromMe: true,
    isSent: true,
    isDelivered: true,
    dateDelivered: deliveredAt
  )
  try insertSentMessageFixture(
    db,
    rowID: 33,
    chatID: 1,
    text: "pending",
    guid: "pending-guid",
    date: deliveredAt,
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(try store.messageSendStatus(guid: "failed-guid")?.state == .failed)
  #expect(try store.messageSendStatus(guid: "sent-guid")?.state == .sent)
  let delivered = try store.messageSendStatus(guid: "delivered-guid")
  #expect(delivered?.state == .delivered)
  #expect(delivered?.dateDelivered != nil)
  #expect(try store.messageSendStatus(guid: "pending-guid")?.state == .pending)
  #expect(try store.messageSendStatus(guid: "DELIVERED-GUID")?.state == .delivered)
  #expect(try store.messageSendStatus(guid: "missing-guid") == nil)
}

private func makeSentMessageDatabase() throws -> Connection {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
      guid TEXT,
      associated_message_guid TEXT,
      associated_message_type INTEGER,
      date INTEGER,
      date_delivered INTEGER,
      date_read INTEGER,
      is_from_me INTEGER,
      service TEXT,
      error INTEGER DEFAULT 0,
      is_sent INTEGER DEFAULT 0,
      is_delivered INTEGER DEFAULT 0,
      is_finished INTEGER DEFAULT 0,
      is_delayed INTEGER DEFAULT 0,
      is_prepared INTEGER DEFAULT 0,
      is_pending_satellite_send INTEGER DEFAULT 0,
      was_downgraded INTEGER DEFAULT 0
    );
    """
  )
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      chat_identifier TEXT,
      guid TEXT,
      display_name TEXT,
      service_name TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, 'iMessage;+;one', 'iMessage;+;one', 'One', 'iMessage'),
           (2, 'iMessage;+;two', 'iMessage;+;two', 'Two', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, 'me@icloud.com')")
  return db
}

private func insertSentMessageFixture(
  _ db: Connection,
  rowID: Int64,
  chatID: Int64,
  text: String,
  attributedBody: Data? = nil,
  guid: String,
  date: Date,
  isFromMe: Bool,
  error: Int = 0,
  isSent: Bool = false,
  isDelivered: Bool = false,
  dateDelivered: Date? = nil
) throws {
  let bodyBlob: Binding? = attributedBody.map { Blob(bytes: [UInt8]($0)) }
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, attributedBody, guid, associated_message_guid, associated_message_type,
      date, date_delivered, is_from_me, service, error, is_sent, is_delivered, is_finished
    )
    VALUES (?, 1, ?, ?, ?, NULL, 0, ?, ?, ?, 'iMessage', ?, ?, ?, 1)
    """,
    rowID,
    text,
    bodyBlob,
    guid,
    TestDatabase.appleEpoch(date),
    dateDelivered.map { TestDatabase.appleEpoch($0) } ?? 0,
    isFromMe ? 1 : 0,
    error,
    isSent ? 1 : 0,
    isDelivered ? 1 : 0
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
}

private func insertAttributedSentMessageFixture(
  _ db: Connection,
  rowID: Int64,
  chatID: Int64,
  text: String,
  guid: String,
  date: Date
) throws {
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array(text.utf8) + [0x86, 0x84]
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, attributedBody, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service
    )
    VALUES (?, 1, NULL, ?, ?, NULL, 0, ?, 1, 'iMessage')
    """,
    rowID,
    Blob(bytes: bodyBytes),
    guid,
    TestDatabase.appleEpoch(date)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
}

private func attributedBodyFixture(_ text: String) -> Data {
  let bytes: [UInt8] =
    [0x01, 0x2b, UInt8(text.utf8.count)] + Array(text.utf8) + [0x86, 0x84]
  return Data(bytes)
}
