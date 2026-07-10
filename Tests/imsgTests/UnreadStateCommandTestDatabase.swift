import Foundation
import SQLite

@testable import IMsgCore

enum UnreadStateCommandTestDatabase {
  static func makePath() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("chat.db").path
    let db = try Connection(path)
    try createSchema(db)
    try seedChats(db)
    return path
  }

  static func makeStoreForRPC() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db)
    try seedRPCChat(db)
    return try MessageStore(connection: db, path: ":memory:")
  }

  private static func createSchema(_ db: Connection) throws {
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        is_read INTEGER,
        date_read INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT,
        account_id TEXT,
        account_login TEXT,
        last_addressed_handle TEXT
      );
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
      );
      """
    )
  }

  private static func seedRPCChat(_ db: Connection) throws {
    let now = Date()
    let readAt = Date(timeIntervalSince1970: 1_700_000_000)
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES (
        1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group Chat', 'iMessage',
        'iMessage;+;me@icloud.com', 'me@icloud.com', 'me@icloud.com'
      )
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
      VALUES
        (5, 1, 'unread', ?, 0, 'iMessage', 0, 0),
        (6, 1, 'read', ?, 0, 'iMessage', 1, ?)
      """,
      CommandTestDatabase.appleEpoch(now),
      CommandTestDatabase.appleEpoch(now),
      CommandTestDatabase.appleEpoch(readAt)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5), (1, 6)")
  }

  private static func seedChats(_ db: Connection) throws {
    let now = Date()
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES
        (1, 'iMessage;-;+123', 'iMessage;-;+123', '', 'iMessage',
         'iMessage;-;me@icloud.com', 'me@icloud.com', 'me@icloud.com'),
        (2, 'iMessage;-;+456', 'iMessage;-;+456', '', 'iMessage',
         'iMessage;-;me@icloud.com', 'me@icloud.com', 'me@icloud.com')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (2, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
      VALUES
        (5, 1, 'unread', ?, 0, 'iMessage', 0, 0),
        (6, 2, 'read', ?, 0, 'iMessage', 1, ?)
      """,
      CommandTestDatabase.appleEpoch(now),
      CommandTestDatabase.appleEpoch(now),
      CommandTestDatabase.appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5), (2, 6)")
  }
}
