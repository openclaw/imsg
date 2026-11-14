import Foundation
import SQLite

extension MessageStore {
  public func sentAttachmentReceipt(matchingPath path: String, chatID: Int64, since date: Date)
    throws -> Message?
  {
    try sentAttachmentReceipt(matchingPath: path, chatID: chatID, since: date, service: .auto)
  }

  package func sentAttachmentReceipt(
    matchingPath path: String, chatID: Int64, since date: Date, service: MessageService
  ) throws -> Message? {
    try sentAttachmentReceipt(matchingPath: path, chatIDs: [chatID], since: date, service: service)
  }

  package func sentAttachmentReceipt(
    matchingPath path: String, chatIDs: [Int64], since date: Date, service: MessageService
  ) throws -> Message? {
    let chatIDs = Array(Set(chatIDs)).sorted()
    guard !path.isEmpty, !chatIDs.isEmpty else { return nil }
    let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
    let absolutePath = NSString(string: path).expandingTildeInPath
    let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
    let storedPath =
      absolutePath.hasPrefix(home) ? "~/" + absolutePath.dropFirst(home.count) : absolutePath
    let selection = MessageRowSelection(store: self)
    let sql = """
      SELECT \(selection.selectList),
             (SELECT MIN(chat_id) FROM chat_message_join
              WHERE message_id = m.ROWID AND chat_id IN (\(placeholders))) AS receipt_chat_id
      FROM message m
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 1 AND m.date >= ?
        AND EXISTS (SELECT 1 FROM chat_message_join cmj
                    WHERE cmj.message_id = m.ROWID AND cmj.chat_id IN (\(placeholders)))
        AND EXISTS (SELECT 1 FROM message_attachment_join maj
                    JOIN attachment a ON a.ROWID = maj.attachment_id
                    WHERE maj.message_id = m.ROWID AND a.filename IN (?, ?))
      LIMIT 2
      """
    return try withConnection { db in
      let bindings: [Binding?] =
        chatIDs.map { $0 as Binding? }
        + [try Self.appleEpoch(date)] + chatIDs.map { $0 as Binding? }
        + [absolutePath, storedPath]
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      guard let row = try rows.failableNext() else { return nil }
      // Each dispatch stages a unique path. Multiple matching messages are ambiguous.
      guard try rows.failableNext() == nil else { return nil }
      guard let chatID = try int64Value(row, "receipt_chat_id") else { return nil }
      let decoded = try decodeMessageRow(
        row, columns: selection.columns, fallbackChatID: chatID)
      guard service.matchesReceiptService(decoded.service) else { return nil }
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
