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
    guard limit > 0 else { return [] }
    let exact = match.lowercased() == "exact"
    var physicalLimit = limit

    return try withConnection { db in
      while true {
        let query = SearchMessagesQuery(
          store: self,
          text: trimmed,
          exact: exact,
          limit: physicalLimit
        )
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
          messages.append(
            try message(
              from: decoded,
              db,
              parentCache: &parentCache,
              pollOptionCache: &pollOptionCache
            ))
        }
        var usedFallbackReplacement = false
        let coalesced = try coalesceURLPreviewMessages(
          messages,
          validateExistingCoalescence: { text, preview in
            try self.precedingTextMessageForURLPreview(preview, db: db)?.rowID == text.rowID
          },
          fallbackForUnmatchedPreview: { preview in
            guard let previous = try self.precedingTextMessageForURLPreview(preview, db: db) else {
              return nil
            }
            guard self.searchMessage(previous, matches: trimmed, exact: exact) else {
              return nil
            }
            return .replace(previous)
          },
          fallbackReplacementUsed: {
            usedFallbackReplacement = true
          }
        ).sorted(by: searchMessagesNewestFirst)

        if messages.count < physicalLimit || (coalesced.count >= limit && !usedFallbackReplacement)
        {
          return Array(coalesced.prefix(limit))
        }
        guard let nextLimit = nextSearchPhysicalLimit(after: physicalLimit) else {
          return Array(coalesced.prefix(limit))
        }
        physicalLimit = nextLimit
      }
    }
  }

  private func searchMessage(_ message: Message, matches text: String, exact: Bool) -> Bool {
    if exact {
      return message.text.caseInsensitiveCompare(text) == .orderedSame
    }
    return message.text.range(of: text, options: [.caseInsensitive]) != nil
  }

  private func nextSearchPhysicalLimit(after current: Int) -> Int? {
    guard current > 0, current <= Int.max / 2 else { return nil }
    return current * 2
  }

  private func searchMessagesNewestFirst(_ lhs: Message, _ rhs: Message) -> Bool {
    if lhs.date == rhs.date {
      return lhs.rowID > rhs.rowID
    }
    return lhs.date > rhs.date
  }
}
