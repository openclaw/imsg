import Foundation
import SQLite

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
      reply_to_guid TEXT,
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
  replyToGUID: String? = nil,
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
      reply_to_guid, balloon_bundle_id, is_read, date_read, date, is_from_me, service
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'iMessage')
    """,
    rowID,
    handleID,
    text,
    guid,
    associatedMessageGUID,
    associatedMessageType,
    replyToGUID,
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
