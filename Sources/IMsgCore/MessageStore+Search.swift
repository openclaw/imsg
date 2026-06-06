import Foundation
import SQLite

private struct SearchMessagesQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64? = nil

  init(store: MessageStore, text: String, exact: Bool, limit: Int) {
    self.selection = MessageRowSelection(store: store, includeChatID: true)
    let reactionFilter =
      store.schema.hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    let predicate =
      exact
      ? "IFNULL(m.text, '') = ? COLLATE NOCASE"
      : "IFNULL(m.text, '') LIKE ? ESCAPE '\\' COLLATE NOCASE"
    let textBinding = exact ? text : SearchMessagesQuery.likePattern(for: text)
    self.sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE \(predicate)\(reactionFilter)
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT ?
      """
    self.bindings = [textBinding, limit]
  }

  private static func likePattern(for text: String) -> String {
    var escaped = ""
    for char in text {
      if char == "\\" || char == "%" || char == "_" {
        escaped.append("\\")
      }
      escaped.append(char)
    }
    return "%\(escaped)%"
  }
}

extension MessageStore {
  public func searchMessages(query text: String, match: String, limit: Int) throws -> [Message] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let exact = match.lowercased() == "exact"
    let query = SearchMessagesQuery(
      store: self,
      text: trimmed,
      exact: exact,
      limit: limit
    )

    return try withConnection { db in
      var messages: [Message] = []
      var parentCache: ReplyParentCache = [:]
      var pollOptionCache = PollOptionTextCache()
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
        let poll = try enrichedPollEvent(
          decoded.poll,
          db: db,
          cache: &pollOptionCache
        )
        let replyToGUID = routedReplyToGUID(decoded)
        let threadOriginatorGUID =
          decoded.threadOriginatorGUID.isEmpty ? nil : decoded.threadOriginatorGUID
        let threadOriginatorPart =
          decoded.threadOriginatorPart.isEmpty ? nil : decoded.threadOriginatorPart
        let parent = enrichedReplyContext(
          db,
          replyToGUID: replyToGUID,
          threadOriginatorGUID: threadOriginatorGUID,
          cache: &parentCache
        )
        messages.append(
          Message(
            rowID: decoded.rowID,
            chatID: decoded.chatID,
            sender: decoded.sender,
            text: decoded.text,
            date: decoded.date,
            isFromMe: decoded.isFromMe,
            service: decoded.service,
            handleID: decoded.handleID,
            attachmentsCount: decoded.attachments,
            guid: decoded.guid,
            routing: Message.RoutingMetadata(
              replyToGUID: replyToGUID,
              threadOriginatorGUID: threadOriginatorGUID,
              threadOriginatorPart: threadOriginatorPart,
              destinationCallerID: decoded.destinationCallerID.isEmpty
                ? nil : decoded.destinationCallerID,
              replyToText: parent?.text,
              replyToSender: parent?.sender
            ),
            balloonBundleID: decoded.balloonBundleID.isEmpty ? nil : decoded.balloonBundleID,
            poll: poll
          ))
      }
      return messages
    }
  }
}
