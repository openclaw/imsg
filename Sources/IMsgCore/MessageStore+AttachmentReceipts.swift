import Foundation
import SQLite

extension MessageStore {
  public func sentAttachmentReceipt(matchingPath path: String, chatID: Int64, since date: Date)
    throws -> Message?
  {
    guard !path.isEmpty else { return nil }
    let absolutePath = NSString(string: path).expandingTildeInPath
    let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
    let storedPath =
      absolutePath.hasPrefix(home) ? "~/" + absolutePath.dropFirst(home.count) : absolutePath
    let selection = MessageRowSelection(store: self)
    let sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 1 AND m.date >= ?
        AND EXISTS (SELECT 1 FROM chat_message_join cmj
                    WHERE cmj.message_id = m.ROWID AND cmj.chat_id = ?)
        AND EXISTS (SELECT 1 FROM message_attachment_join maj
                    JOIN attachment a ON a.ROWID = maj.attachment_id
                    WHERE maj.message_id = m.ROWID AND a.filename IN (?, ?))
      LIMIT 2
      """
    return try withConnection { db in
      let rows = try db.prepareRowIterator(
        sql, bindings: [try Self.appleEpoch(date), chatID, absolutePath, storedPath])
      guard let row = try rows.failableNext() else { return nil }
      // Each dispatch stages a unique path. Multiple matching messages are ambiguous.
      guard try rows.failableNext() == nil else { return nil }
      let decoded = try decodeMessageRow(
        row, columns: selection.columns, fallbackChatID: chatID)
      return Message(
        rowID: decoded.rowID,
        chatID: chatID,
        sender: decoded.sender,
        text: decoded.text,
        date: decoded.date,
        isFromMe: decoded.isFromMe,
        service: decoded.service,
        handleID: decoded.handleID,
        attachmentsCount: decoded.attachments,
        guid: decoded.guid)
    }
  }
}
