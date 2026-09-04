import Foundation
import SQLite

#if os(Linux)
  import SQLiteSwiftCSQLite
#else
  import SQLite3
#endif

func messageSearchMatches(_ candidate: String, query: String, exact: Bool) -> Bool {
  if exact {
    return candidate.caseInsensitiveCompare(query) == .orderedSame
  }
  return candidate.range(of: query, options: [.caseInsensitive]) != nil
}

func registerMessageSearch(in db: Connection) throws {
  // SQLite.swift's block registration crashes on Linux (upstream #1071).
  // This C callback captures no state and lives with the connection.
  let result = sqlite3_create_function_v2(
    db.handle, "imsg_search_text", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
    { context, _, args in
      guard let args, let candidate = sqlite3_value_text(args[0]),
        let query = sqlite3_value_text(args[1])
      else {
        sqlite3_result_int(context, 0)
        return
      }
      let matches = messageSearchMatches(
        String(cString: candidate), query: String(cString: query),
        exact: sqlite3_value_int(args[2]) != 0)
      sqlite3_result_int(context, matches ? 1 : 0)
    }, nil, nil, nil)
  guard result == SQLITE_OK else {
    throw SQLite.Result.error(
      message: String(cString: sqlite3_errmsg(db.handle)), code: result, statement: nil)
  }
}

private struct SearchMessagesQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64? = nil

  init(store: MessageStore, text: String, exact: Bool, limit: Int) {
    self.selection = MessageRowSelection(
      store: store, chatIDColumn: MessageRowSelection.canonicalChatID)
    let reactionFilter =
      store.schema.hasReactionColumns
      ? " AND \(nonReactionPredicate("m.associated_message_type"))"
      : ""
    let attributedBodyCandidate =
      store.schema.hasAttributedBody
      ? " OR (IFNULL(m.text, '') = '' AND m.attributedBody IS NOT NULL)"
      : ""
    let audioCandidate =
      store.schema.hasAudioMessageColumn && store.schema.hasAttachmentUserInfo
      ? " OR m.is_audio_message != 0" : ""
    let predicate =
      "(imsg_search_text(IFNULL(m.text, ''), ?, ?)\(attributedBodyCandidate)\(audioCandidate))"
    self.sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE \(predicate)\(reactionFilter)
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT ?
      """
    self.bindings = [text, exact ? 1 : 0, limit]
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
        var candidateCount = 0
        var parentCache: ReplyParentCache = [:]
        var pollOptionCache = PollOptionTextCache()
        let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
        while let row = try rows.failableNext() {
          candidateCount += 1
          let decoded = try decodeMessageRow(
            row,
            columns: query.selection.columns,
            fallbackChatID: query.fallbackChatID
          )
          guard messageSearchMatches(decoded.text, query: trimmed, exact: exact) else { continue }
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
            guard messageSearchMatches(previous.text, query: trimmed, exact: exact) else {
              return nil
            }
            return .replace(previous)
          },
          fallbackReplacementUsed: {
            usedFallbackReplacement = true
          }
        ).sorted(by: messageNewestFirst)

        if candidateCount < physicalLimit
          || (coalesced.count >= limit && !usedFallbackReplacement)
        {
          return Array(coalesced.prefix(limit))
        }
        guard let nextLimit = nextMessageQueryLimit(after: physicalLimit) else {
          return Array(coalesced.prefix(limit))
        }
        physicalLimit = nextLimit
      }
    }
  }

}
