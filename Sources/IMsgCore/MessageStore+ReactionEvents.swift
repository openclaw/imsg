import Foundation
import SQLite

/// A reaction event represents when someone adds or removes a reaction to a message.
/// Unlike `Reaction` which represents the current state, this captures the event itself.
public struct ReactionEvent: Sendable, Equatable {
  /// The ROWID of the reaction message in the database
  public let rowID: Int64
  /// The chat ID where the reaction occurred
  public let chatID: Int64
  /// The type of reaction
  public let reactionType: ReactionType
  /// Whether this is adding (true) or removing (false) a reaction
  public let isAdd: Bool
  /// The sender of the reaction (phone number or email)
  public let sender: String
  /// Whether the reaction was sent by the current user
  public let isFromMe: Bool
  /// When the reaction event occurred
  public let date: Date
  /// The GUID of the message being reacted to
  public let reactedToGUID: String
  /// The ROWID of the message being reacted to (if available)
  public let reactedToID: Int64?
  /// The original text of the reaction message (e.g., "Liked \"hello\"")
  public let text: String

  public init(
    rowID: Int64,
    chatID: Int64,
    reactionType: ReactionType,
    isAdd: Bool,
    sender: String,
    isFromMe: Bool,
    date: Date,
    reactedToGUID: String,
    reactedToID: Int64?,
    text: String
  ) {
    self.rowID = rowID
    self.chatID = chatID
    self.reactionType = reactionType
    self.isAdd = isAdd
    self.sender = sender
    self.isFromMe = isFromMe
    self.date = date
    self.reactedToGUID = reactedToGUID
    self.reactedToID = reactedToID
    self.text = text
  }
}

extension MessageStore {
  /// Fetch reaction events (add/remove) after a given rowID.
  /// These are the reaction messages themselves, useful for streaming reaction events in watch mode.
  public func reactionEventsAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws
    -> [ReactionEvent]
  {
    guard schema.hasReactionColumns else { return [] }

    let bodyColumn = schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    let destinationCallerColumn =
      schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let chatColumn = chatID == nil ? MessageRowSelection.canonicalChatID : "NULL"

    var sql = """
      SELECT m.ROWID AS reaction_rowid, \(chatColumn) AS chat_id,
             m.associated_message_type AS associated_message_type,
             m.associated_message_guid AS associated_message_guid,
             m.handle_id AS handle_id, h.id AS sender, m.is_from_me AS is_from_me,
             m.date AS date, IFNULL(m.text, '') AS text,
             \(destinationCallerColumn) AS destination_caller_id,
             \(bodyColumn) AS body,
             orig.ROWID AS orig_rowid
      FROM message m
      \(chatID == nil ? "" : MessageRowSelection.scopedChatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      LEFT JOIN message orig ON (orig.guid = m.associated_message_guid
        OR m.associated_message_guid LIKE '%/' || orig.guid)
      WHERE m.ROWID > ?
        AND \(reactionPredicate("m.associated_message_type"))
      """
    var bindings: [Binding?] = [afterRowID]

    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var events: [ReactionEvent] = []
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      while let row = try rows.failableNext() {
        let rowID = try int64Value(row, "reaction_rowid") ?? 0
        let resolvedChatID = try int64Value(row, "chat_id") ?? chatID ?? 0
        let typeValue = try intValue(row, "associated_message_type") ?? 0
        let associatedGUID = try stringValue(row, "associated_message_guid")
        var sender = try stringValue(row, "sender")
        let isFromMe = try boolValue(row, "is_from_me")
        let date = try appleDate(from: int64Value(row, "date"))
        let text = try stringValue(row, "text")
        let destinationCallerID = try stringValue(row, "destination_caller_id")
        let body = try dataValue(row, "body")
        let origRowID = try int64Value(row, "orig_rowid")

        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }

        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        let decoded = decodeReaction(
          associatedType: typeValue,
          associatedGUID: associatedGUID,
          text: resolvedText
        )
        guard let reactionType = decoded.reactionType, let isAdd = decoded.isReactionAdd else {
          continue
        }

        events.append(
          ReactionEvent(
            rowID: rowID,
            chatID: resolvedChatID,
            reactionType: reactionType,
            isAdd: isAdd,
            sender: sender,
            isFromMe: isFromMe,
            date: date,
            reactedToGUID: decoded.reactedToGUID ?? "",
            reactedToID: origRowID,
            text: resolvedText
          ))
      }
      return events
    }
  }

}
