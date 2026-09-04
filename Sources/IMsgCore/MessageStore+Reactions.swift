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
      JOIN message r ON r.associated_message_guid = m.guid
        OR r.associated_message_guid LIKE '%/' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND m.guid IS NOT NULL
        AND m.guid != ''
        AND \(reactionPredicate("r.associated_message_type"))
      ORDER BY r.date ASC
      """
    self.bindings = [messageID.rawValue]
  }
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
      var reactionIndex: [ReactionKey: Int] = [:]
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let rowID = try int64Value(row, "reaction_rowid") ?? 0
        let typeValue = try intValue(row, "associated_message_type") ?? 0
        let sender = try stringValue(row, "sender")
        let isFromMe = try boolValue(row, "is_from_me")
        let date = try appleDate(from: int64Value(row, "date"))
        let text = try stringValue(row, "text")
        let body = try dataValue(row, "body")
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

        if ReactionType.isReactionRemove(typeValue) {
          let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
          let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
          if let reactionType {
            let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
            if let index = reactionIndex.removeValue(forKey: key) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
            continue
          }
          if typeValue == 3006 {
            if let index = reactions.firstIndex(where: {
              $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
            }) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
          }
          continue
        }

        let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
        guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
          continue
        }

        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
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

  private struct ReactionKey: Hashable {
    let sender: String
    let isFromMe: Bool
    let reactionType: ReactionType

    static func reindex(reactions: [Reaction]) -> [ReactionKey: Int] {
      var index: [ReactionKey: Int] = [:]
      for (offset, reaction) in reactions.enumerated() {
        let key = ReactionKey(
          sender: reaction.sender,
          isFromMe: reaction.isFromMe,
          reactionType: reaction.reactionType
        )
        index[key] = offset
      }
      return index
    }
  }
}
