import Foundation
import SQLite

enum ChatBackgroundCommandTestDatabase {
  static func makePath() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let messagesDirectory = root.appendingPathComponent("Library/Messages", isDirectory: true)
    try FileManager.default.createDirectory(
      at: messagesDirectory, withIntermediateDirectories: true)
    let databaseURL = messagesDirectory.appendingPathComponent("chat.db")
    let db = try Connection(databaseURL.path)
    try db.execute(
      """
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, properties BLOB);
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        item_type INTEGER,
        group_action_type INTEGER,
        date INTEGER
      );
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      """)

    let properties: [String: Any] = [
      "backgroundProperties": [
        "trabaid": "channel-123",
        "trabar": "file:///background",
        "trabas": "asset-123",
      ]
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: properties,
      format: .binary,
      options: 0
    )
    try db.run(
      "INSERT INTO chat(ROWID, guid, properties) VALUES (1, 'iMessage;+;chat123', ?)",
      Blob(bytes: [UInt8](data))
    )
    try db.run(
      """
      INSERT INTO message(ROWID, guid, item_type, group_action_type, date)
      VALUES (1, 'background-set', 3, 4, ?)
      """,
      CommandTestDatabase.appleEpoch(Date())
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    let cacheRoot = messagesDirectory.appendingPathComponent(
      "TranscriptBackgroundCache",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    try Data().write(to: cacheRoot.appendingPathComponent("channel-123"))
    return databaseURL.path
  }
}
