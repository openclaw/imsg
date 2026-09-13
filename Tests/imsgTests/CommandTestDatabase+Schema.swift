import Foundation
import SQLite

@testable import IMsgCore

extension CommandTestDatabase {
  static func createSchema(
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

}
