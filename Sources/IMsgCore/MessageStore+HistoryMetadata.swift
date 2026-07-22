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
      messageIDByGUID[message.guid] = message.rowID
    }
    guard !messageIDByGUID.isEmpty else { return [:] }

    var reactionsByMessageID: [Int64: [Reaction]] = [:]
    var reactionIndexByMessageID: [Int64: [BulkReactionKey: Int]] = [:]
    var matchedRows: [BulkReactionRow] = []
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
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      """

    try withConnection { db in
      let rows = try db.prepareRowIterator(sql)
      while let row = try rows.failableNext() {
        let associatedGUID = try stringValue(row, "associated_message_guid")
        let baseGUID = baseAssociatedMessageGUID(from: associatedGUID)
        guard let messageID = messageIDByGUID[baseGUID] else { continue }

        let rowID = try int64Value(row, "reaction_rowid") ?? 0
        let typeValue = try intValue(row, "associated_message_type") ?? 0
        let sender = try stringValue(row, "sender")
        let isFromMe = try boolValue(row, "is_from_me")
        let date = try appleDate(from: int64Value(row, "date"))
        let text = try stringValue(row, "text")
        let body = try dataValue(row, "body")
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        matchedRows.append(
          BulkReactionRow(
            rowID: rowID,
            typeValue: typeValue,
            sender: sender,
            isFromMe: isFromMe,
            date: date,
            resolvedText: resolvedText,
            messageID: messageID
          )
        )
      }
    }
    matchedRows.sort {
      $0.date == $1.date ? $0.rowID < $1.rowID : $0.date < $1.date
    }
    for row in matchedRows {
      var reactions = reactionsByMessageID[row.messageID, default: []]
      var reactionIndex = reactionIndexByMessageID[row.messageID] ?? [:]
      applyBulkReactionRow(
        rowID: row.rowID,
        typeValue: row.typeValue,
        sender: row.sender,
        isFromMe: row.isFromMe,
        date: row.date,
        resolvedText: row.resolvedText,
        messageID: row.messageID,
        reactions: &reactions,
        reactionIndex: &reactionIndex
      )
      reactionsByMessageID[row.messageID] = reactions
      reactionIndexByMessageID[row.messageID] = reactionIndex
    }
    return reactionsByMessageID
  }

  private func baseAssociatedMessageGUID(from associatedGUID: String) -> String {
    guard let slashIndex = associatedGUID.lastIndex(of: "/") else { return associatedGUID }
    let guidStart = associatedGUID.index(after: slashIndex)
    return String(associatedGUID[guidStart...])
  }

  private func applyBulkReactionRow(
    rowID: Int64,
    typeValue: Int,
    sender: String,
    isFromMe: Bool,
    date: Date,
    resolvedText: String,
    messageID: Int64,
    reactions: inout [Reaction],
    reactionIndex: inout [BulkReactionKey: Int]
  ) {
    if ReactionType.isReactionRemove(typeValue) {
      let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
      let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
      if let reactionType {
        let key = BulkReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
        if let index = reactionIndex.removeValue(forKey: key) {
          reactions.remove(at: index)
          reactionIndex = BulkReactionKey.reindex(reactions: reactions)
        }
        return
      }
      if typeValue == 3006 {
        if let index = reactions.firstIndex(where: {
          $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
        }) {
          reactions.remove(at: index)
          reactionIndex = BulkReactionKey.reindex(reactions: reactions)
        }
      }
      return
    }

    let customEmoji = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
    guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
      return
    }

    let key = BulkReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
    if let index = reactionIndex[key] {
      reactions[index] = Reaction(
        rowID: rowID,
        reactionType: reactionType,
        sender: sender,
        isFromMe: isFromMe,
        date: date,
        associatedMessageID: messageID
      )
    } else {
      reactionIndex[key] = reactions.count
      reactions.append(
        Reaction(
          rowID: rowID,
          reactionType: reactionType,
          sender: sender,
          isFromMe: isFromMe,
          date: date,
          associatedMessageID: messageID
        ))
    }
  }

  private struct BulkReactionKey: Hashable {
    let sender: String
    let isFromMe: Bool
    let reactionType: ReactionType

    static func reindex(reactions: [Reaction]) -> [BulkReactionKey: Int] {
      var index: [BulkReactionKey: Int] = [:]
      for (offset, reaction) in reactions.enumerated() {
        let key = BulkReactionKey(
          sender: reaction.sender,
          isFromMe: reaction.isFromMe,
          reactionType: reaction.reactionType
        )
        index[key] = offset
      }
      return index
    }
  }

  private struct BulkReactionRow {
    let rowID: Int64
    let typeValue: Int
    let sender: String
    let isFromMe: Bool
    let date: Date
    let resolvedText: String
    let messageID: Int64
  }
}
