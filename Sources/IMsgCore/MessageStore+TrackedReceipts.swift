import Foundation

extension MessageStore {
  package func hasTrackedSendReceipt(guid: String, chatTarget: String, afterRowID: Int64) throws
    -> Bool
  {
    try withConnection { db in
      let rows = try db.prepareRowIterator(
        """
        SELECT 1 AS found FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.guid = ? COLLATE NOCASE AND m.ROWID > ? AND m.is_from_me = 1
          AND (c.guid = ? OR c.chat_identifier = ?)
        LIMIT 1
        """,
        bindings: [guid, afterRowID, chatTarget, chatTarget])
      return try rows.failableNext() != nil
    }
  }
}
