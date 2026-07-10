import Foundation
import SQLite

@testable import IMsgCore

enum CommandTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makePath() throws -> String {
    let path = try makeDatabasePath()
    let db = try Connection(path)
    try createSchema(db, includeChatHandleJoin: true)
    try seedBasicChat(db)
    return path
  }

  static func makePathDirectChat() throws -> String {
    let path = try makePath()
    let db = try Connection(path)
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = '+123', guid = 'iMessage;-;+123', display_name = 'Direct Chat'
      WHERE ROWID = 1
      """
    )
    return path
  }

  static func makePathWithAttachment(
    filename: String = "/tmp/file.dat",
    transferName: String = "file.dat",
    uti: String = "public.data",
    mimeType: String = "application/octet-stream"
  ) throws -> String {
    let path = try makePath()
    let db = try Connection(path)
    try db.run(
      """
      INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
      VALUES (1, ?, ?, ?, ?, 10, 0)
      """,
      filename,
      transferName,
      uti,
      mimeType
    )
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")
    return path
  }

  static func makeStoreForRPC() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true)
    try seedRPCChat(db)
    return try MessageStore(
      connection: db,
      path: ":memory:",
      hasAttributedBody: false,
      hasReactionColumns: false
    )
  }

  static func makeStoreForRPCDirectChat() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true)
    try seedRPCChat(db)
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = '+123', guid = 'iMessage;-;+123', display_name = 'Direct Chat'
      WHERE ROWID = 1
      """
    )
    return try MessageStore(
      connection: db,
      path: ":memory:",
      hasAttributedBody: false,
      hasReactionColumns: false
    )
  }

  static func makeStoreForRPCWithAttachment(
    filename: String,
    transferName: String,
    uti: String,
    mimeType: String
  ) throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true)
    try seedRPCChat(db)
    try db.run(
      """
      INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
      VALUES (1, ?, ?, ?, ?, 10, 0)
      """,
      filename,
      transferName,
      uti,
      mimeType
    )
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (5, 1)")
    return try MessageStore(
      connection: db,
      path: ":memory:",
      hasAttributedBody: false,
      hasReactionColumns: false
    )
  }

  static func makeStoreForRPCWithReaction() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true, includeReactionColumns: true)
    try seedRPCChat(db)
    try db.run("UPDATE message SET guid = 'msg-guid-5' WHERE ROWID = 5")
    try db.run(
      """
      INSERT INTO message(
        ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
        date, is_from_me, service
      )
      VALUES (6, 2, '', 'reaction-guid-6', 'p:0/msg-guid-5', 2001, ?, 0, 'iMessage')
      """,
      appleEpoch(Date().addingTimeInterval(1))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
    return try MessageStore(connection: db, path: ":memory:")
  }

  static func makeStoreForRPCWithPollVote() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(
      db,
      includeChatHandleJoin: true,
      includeReactionColumns: true,
      includePollColumns: true
    )
    try seedRPCChat(db)
    let now = Date()
    let creationPayload = try pollPayload(
      jsonObject: [
        "title": "Ship it?",
        "orderedPollOptions": [
          ["optionIdentifier": "choice-yes", "pollOptionText": "Yes"],
          ["optionIdentifier": "choice-no", "pollOptionText": "No"],
        ],
      ])
    let votePayload = try pollPayload(
      jsonObject: [
        "votes": [
          [
            "voteOptionIdentifier": "choice-yes",
            "participantHandle": "+123",
            "eventType": "selected",
          ]
        ]
      ])
    try db.run(
      """
      INSERT INTO message(
        ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
        balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
      )
      VALUES (6, 2, '', 'poll-guid-6', NULL, NULL, ?, ?, NULL, ?, 1, 'iMessage')
      """,
      "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls",
      Blob(bytes: [UInt8](creationPayload)),
      appleEpoch(now.addingTimeInterval(1))
    )
    try db.run(
      """
      INSERT INTO message(
        ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
        balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
      )
      VALUES (7, 1, '', 'poll-vote-guid-7', 'p:0/poll-guid-6', 4000, NULL, ?, NULL, ?, 0, 'iMessage')
      """,
      Blob(bytes: [UInt8](votePayload)),
      appleEpoch(now.addingTimeInterval(2))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 7)")
    return try MessageStore(connection: db, path: ":memory:")
  }

  private static func makeDatabasePath() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("chat.db").path
  }

  private static func createSchema(
    _ db: Connection,
    includeChatHandleJoin: Bool,
    includeReactionColumns: Bool = false,
    includePollColumns: Bool = false
  ) throws {
    let reactionColumns =
      includeReactionColumns
      ? [
        "guid TEXT",
        "associated_message_guid TEXT",
        "associated_message_type INTEGER",
      ].joined(separator: ",\n") + ","
      : ""
    let pollColumns =
      includePollColumns
      ? [
        "balloon_bundle_id TEXT",
        "payload_data BLOB",
        "message_summary_info BLOB",
      ].joined(separator: ",\n") + ","
      : ""
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        \(reactionColumns)
        \(pollColumns)
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
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
        service_name TEXT,
        account_id TEXT,
        account_login TEXT,
        last_addressed_handle TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    if includeChatHandleJoin {
      try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    }
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.execute(
      """
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

  private static func seedBasicChat(_ db: Connection) throws {
    let now = Date()
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES (
        1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage',
        'iMessage;+;me@icloud.com', 'me@icloud.com', '+15551234567'
      )
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (1, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  }

  private static func seedRPCChat(_ db: Connection) throws {
    let now = Date()
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
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (5, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }

  private static func pollPayload(jsonObject: [String: Any]) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    let encoded = json.base64EncodedString()
    let url = URL(string: "data:,\(encoded)")!
    return try NSKeyedArchiver.archivedData(
      withRootObject: [
        "URL": url,
        "sessionIdentifier": UUID(),
        "an": "Polls",
      ],
      requiringSecureCoding: false
    )
  }
}
