import Foundation
import SQLite

private struct CurrentReactionsQuery {
  let sql: String
  let bindings: [Binding?]

  init(messageID: MessageID, schema: MessageStoreSchema) {
    let bodyColumn = schema.hasAttributedBody ? "r.attributedBody" : "NULL"
    self.sql = """
      SELECT r.ROWID AS reaction_rowid, r.associated_message_type AS associated_message_type,
             h.id AS sender, r.is_from_me AS is_from_me, r.date AS date, IFNULL(r.text, '') AS text,
             \(bodyColumn) AS body
      FROM message m
      JOIN message r ON r.associated_message_guid = m.guid COLLATE NOCASE
        OR r.associated_message_guid LIKE '%/' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND m.guid IS NOT NULL
        AND m.guid != ''
        AND \(reactionPredicate("r.associated_message_type"))
      ORDER BY r.date ASC, r.ROWID ASC
      """
    self.bindings = [messageID.rawValue]
  }
}

struct ReactionRow {
  let rowID: Int64
  let typeValue: Int
  let sender: String
  let isFromMe: Bool
  let timestamp: Int64
  let resolvedText: String
  let messageID: Int64
}

extension MessageStore {
  public func reactions(for messageID: Int64) throws -> [Reaction] {
    guard schema.hasReactionColumns else { return [] }
    let query = CurrentReactionsQuery(
      messageID: MessageID(rawValue: messageID),
      schema: schema
    )
    return try withConnection { db in
      var reactions: [Reaction] = []
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        applyReactionRow(try decodeReactionRow(row, messageID: messageID), to: &reactions)
      }
      return reactions
    }
  }

  /// Extract custom emoji from reaction message text like "Reacted 🎉 to "original message""
  func extractCustomEmoji(from text: String) -> String? {
    guard
      let reactedRange = text.range(of: "Reacted "),
      let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
    else {
      return extractFirstEmoji(from: text)
    }
    let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
    return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
  }

  private func extractFirstEmoji(from text: String) -> String? {
    for character in text {
      if character.unicodeScalars.contains(where: {
        $0.properties.isEmojiPresentation || $0.properties.isEmoji
      }) {
        return String(character)
      }
    }
    return nil
  }

  func decodeReactionRow(_ row: Row, messageID: Int64) throws -> ReactionRow {
    let text = try stringValue(row, "text")
    let body = try dataValue(row, "body")
    return ReactionRow(
      rowID: try int64Value(row, "reaction_rowid") ?? 0,
      typeValue: try intValue(row, "associated_message_type") ?? 0,
      sender: try stringValue(row, "sender"),
      isFromMe: try boolValue(row, "is_from_me"),
      timestamp: try int64Value(row, "date") ?? 0,
      resolvedText: text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text,
      messageID: messageID)
  }

  func applyReactionRow(_ row: ReactionRow, to reactions: inout [Reaction]) {
    let removal = ReactionType.isReactionRemove(row.typeValue)
    let emoji =
      row.typeValue == 2006 || row.typeValue == 3006
      ? extractCustomEmoji(from: row.resolvedText) : nil
    let type =
      removal
      ? ReactionType.fromRemoval(row.typeValue, customEmoji: emoji)
      : ReactionType(rawValue: row.typeValue, customEmoji: emoji)
    let index = reactions.firstIndex {
      $0.sender == row.sender && $0.isFromMe == row.isFromMe
        && ($0.reactionType == type
          || (row.typeValue == 3006 && type == nil && $0.reactionType.isCustom))
    }
    if removal {
      if let index { reactions.remove(at: index) }
      return
    }
    guard let type else { return }
    let reaction = Reaction(
      rowID: row.rowID, reactionType: type, sender: row.sender, isFromMe: row.isFromMe,
      date: appleDate(from: row.timestamp), associatedMessageID: row.messageID)
    if let index {
      reactions[index] = reaction
    } else {
      reactions.append(reaction)
    }
  }
}
