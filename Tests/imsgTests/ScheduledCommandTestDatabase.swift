import Foundation
import SQLite

@testable import IMsgCore

enum ScheduledCommandTestDatabase {
  static func makePath() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("chat.db").path
    let db = try Connection(path)
    try createSchema(db)
    try seed(db)
    return path
  }

  static func makeStoreForRPC() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db)
    try seed(db)
    return try MessageStore(connection: db, path: ":memory:")
  }

  private static func createSchema(_ db: Connection) throws {
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        handle_id INTEGER,
        text TEXT,
        schedule_type INTEGER,
        schedule_state INTEGER,
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
      """)
  }

  private static func seed(_ db: Connection) throws {
    let first = CommandTestDatabase.appleEpoch(Date().addingTimeInterval(3600))
    let second = CommandTestDatabase.appleEpoch(Date().addingTimeInterval(7200))
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      ) VALUES (
        1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage',
        'iMessage;-;me@icloud.com', 'me@icloud.com', 'me@icloud.com'
      )
      """)
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1)")
    try db.run(
      """
      INSERT INTO message(
        ROWID, guid, handle_id, text, schedule_type, schedule_state, date, is_from_me, service
      ) VALUES
        (1, 'scheduled-one', 1, 'later one', 2, 1, ?, 1, 'iMessage'),
        (2, 'scheduled-two', 1, 'later two', 2, 1, ?, 1, 'iMessage')
      """,
      first,
      second
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2)")
  }
}
