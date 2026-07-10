import SQLite

extension MessageStore {
  public func messageBelongsToChat(messageGUID: String, chatGUID: String) throws -> Bool {
    guard !messageGUID.isEmpty, !chatGUID.isEmpty else { return false }
    return try withConnection { db in
      let rows = try db.prepareRowIterator(
        """
        SELECT 1 AS found
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.guid = ? AND c.guid = ?
        LIMIT 1
        """,
        bindings: [messageGUID, chatGUID]
      )
      return try rows.failableNext() != nil
    }
  }
}
