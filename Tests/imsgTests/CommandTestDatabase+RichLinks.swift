import SQLite

@testable import IMsgCore

extension CommandTestDatabase {
  static func makeStoreForRPCWithSharedIdentifier() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true)
    try seedRPCChat(db)
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = '+123', guid = 'iMessage;-;+123', display_name = 'iMessage Chat'
      WHERE ROWID = 1
      """
    )
    // Keep the SMS row newest so row-order-only resolution would select the wrong service.
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES (
        2, '+123', 'SMS;-;+123', 'SMS Chat', 'SMS',
        'SMS;-;me', 'me', '+123'
      )
      """
    )
    return try MessageStore(
      connection: db,
      path: ":memory:",
      hasAttributedBody: false,
      hasReactionColumns: false
    )
  }
}
