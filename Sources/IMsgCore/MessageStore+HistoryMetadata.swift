import Foundation
import SQLite

extension MessageStore {
  private static let bulkAttachmentBatchSize = 500

  public func attachments(
    for messageIDs: [Int64],
    options: AttachmentQueryOptions = .default
  ) throws -> [Int64: [AttachmentMeta]] {
    let uniqueIDs = Array(Set(messageIDs)).sorted()
    guard !uniqueIDs.isEmpty else { return [:] }

    var metasByMessageID: [Int64: [AttachmentMeta]] = [:]
    for start in stride(from: 0, to: uniqueIDs.count, by: Self.bulkAttachmentBatchSize) {
      let end = min(start + Self.bulkAttachmentBatchSize, uniqueIDs.count)
      let batch = Array(uniqueIDs[start..<end])
      let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
      let sql = """
        SELECT maj.message_id AS message_id, a.filename AS filename,
               a.transfer_name AS transfer_name, a.uti AS uti, a.mime_type AS mime_type,
               a.total_bytes AS total_bytes, a.is_sticker AS is_sticker
        FROM message_attachment_join maj
        JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE maj.message_id IN (\(placeholders))
        ORDER BY maj.message_id ASC
        """
      let bindings: [Binding?] = batch.map { $0 }
      try withConnection { db in
        let rows = try db.prepareRowIterator(sql, bindings: bindings)
        while let row = try rows.failableNext() {
          let messageID = try int64Value(row, "message_id") ?? 0
          let filename = try stringValue(row, "filename")
          let transferName = try stringValue(row, "transfer_name")
          let uti = try stringValue(row, "uti")
          let mimeType = try stringValue(row, "mime_type")
          let totalBytes = try int64Value(row, "total_bytes") ?? 0
          let isSticker = try boolValue(row, "is_sticker")
          metasByMessageID[messageID, default: []].append(
            AttachmentResolver.metadata(
              filename: filename,
              transferName: transferName,
              uti: uti,
              mimeType: mimeType,
              totalBytes: totalBytes,
              isSticker: isSticker,
              options: options
            ))
        }
      }
    }
    return metasByMessageID
  }

  public func reactions(for messages: [Message]) throws -> [Int64: [Reaction]] {
    guard schema.hasReactionColumns else { return [:] }

    var messageIDByGUID: [String: Int64] = [:]
    for message in messages where !message.guid.isEmpty {
      messageIDByGUID[message.guid.lowercased()] = message.rowID
    }
    guard !messageIDByGUID.isEmpty else { return [:] }

    var reactionsByMessageID: [Int64: [Reaction]] = [:]
    var matchedRows: [ReactionRow] = []
    let bodyColumn = schema.hasAttributedBody ? "r.attributedBody" : "NULL"
    // A reaction can be joined to a different chat than its target. Scan the indexed
    // associated-message rows once, then match only the requested GUIDs in memory.
    let sql = """
      SELECT r.ROWID AS reaction_rowid, r.associated_message_guid AS associated_message_guid,
             r.associated_message_type AS associated_message_type, h.id AS sender,
             r.is_from_me AS is_from_me, r.date AS date, IFNULL(r.text, '') AS text,
             \(bodyColumn) AS body
      FROM message r
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE r.associated_message_guid IS NOT NULL
        AND r.associated_message_guid != ''
        AND \(reactionPredicate("r.associated_message_type"))
      """

    try withConnection { db in
      let rows = try db.prepareRowIterator(sql)
      while let row = try rows.failableNext() {
        let associatedGUID = try stringValue(row, "associated_message_guid")
        let baseGUID = normalizeAssociatedGUID(associatedGUID).lowercased()
        guard let messageID = messageIDByGUID[baseGUID] else { continue }

        matchedRows.append(try decodeReactionRow(row, messageID: messageID))
      }
    }
    // Preserve nanosecond order before converting timestamps to Foundation Date.
    matchedRows.sort {
      $0.timestamp == $1.timestamp ? $0.rowID < $1.rowID : $0.timestamp < $1.timestamp
    }
    for row in matchedRows {
      applyReactionRow(row, to: &reactionsByMessageID[row.messageID, default: []])
    }
    return reactionsByMessageID
  }
}
