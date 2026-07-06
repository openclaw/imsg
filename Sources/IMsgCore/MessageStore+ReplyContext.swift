import Foundation
import SQLite

typealias ReplyParent = (text: String, sender: String)

/// Per-query-loop memoization for parent message lookups. Reused across rows
/// within one `messages()`/`messagesAfter()`/`searchMessages()` invocation so
/// large pulls with many replies that share a parent (common in active group
/// threads) issue a single SELECT per distinct parent guid rather than one per
/// reply row.
///
/// Both hits and misses are cached: the outer optional records whether a guid
/// has been looked up; the inner optional records the result. Hits return the
/// parent body + sender; misses (absent parent, SQLite error) short-circuit
/// the next replies to the same guid without re-querying.
typealias ReplyParentCache = [String: ReplyParent?]

extension MessageStore {
  /// Resolves the text + sender handle of a reply parent referenced by
  /// `thread_originator_guid`, `reply_to_guid`, or a non-reaction
  /// `associated_message_guid`. The parent row is decoded through
  /// `decodeMessageRow` so the same attributedBody fallback and sender
  /// resolution applies as for top-level messages. Returns nil when the parent
  /// row is absent or the guid is empty.
  func resolveReplyParent(_ db: Connection, guid: String) throws -> ReplyParent? {
    guard !guid.isEmpty else { return nil }
    let selection = MessageRowSelection(store: self, includeChatID: false)
    let sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.guid = ?
      LIMIT 1
      """
    let rows = try db.prepareRowIterator(sql, bindings: [guid])
    guard let row = try rows.failableNext() else { return nil }
    let decoded = try decodeMessageRow(row, columns: selection.columns, fallbackChatID: nil)
    return (text: decoded.text, sender: decoded.sender)
  }

  /// The caption text of a native poll: the earliest message whose
  /// `reply_to_guid` targets the poll. Native poll comments (the "comment or
  /// Send" field) carry the question in a separate reply message because the
  /// poll balloon has no title, so this is how the question reaches us when the
  /// poll's own `item.title` is empty. Decoded via `decodeMessageRow` for the
  /// same attributedBody fallback as everywhere else.
  func pollCommentText(_ db: Connection, pollGUID: String) throws -> String? {
    guard !pollGUID.isEmpty else { return nil }
    // Older/synthetic message tables may lack reply_to_guid; without it a poll
    // comment cannot be located, so skip the query rather than fail the pull.
    guard schema.hasReplyToGUIDColumn else { return nil }
    let selection = MessageRowSelection(store: self, includeChatID: false)
    // The question caption is a plain message (associated_message_type 0 or NULL)
    // with no thread metadata. A threaded inline reply to the poll (type 100,
    // thread originator set) is NOT the question — exclude it so a reply is never
    // mistaken for the caption. Reply references may use Apple's `p:<part>/GUID`
    // form, so match both the bare and prefixed values. Both association columns
    // are schema-optional, so only add their filters when they exist.
    var conditions = ["(m.reply_to_guid = ? OR m.reply_to_guid LIKE '%/' || ?)"]
    if schema.hasReactionColumns {
      conditions.append("(m.associated_message_type IS NULL OR m.associated_message_type = 0)")
    }
    if schema.hasThreadOriginatorGUIDColumn {
      conditions.append("m.thread_originator_guid IS NULL")
    }
    let sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE \(conditions.joined(separator: " AND "))
      ORDER BY m.date ASC, m.ROWID ASC
      LIMIT 1
      """
    let rows = try db.prepareRowIterator(sql, bindings: [pollGUID, pollGUID])
    guard let row = try rows.failableNext() else { return nil }
    let decoded = try decodeMessageRow(row, columns: selection.columns, fallbackChatID: nil)
    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Walks `threadOriginatorGUID` then `replyToGUID` and returns the first
  /// successful parent resolution, consulting `cache` to amortize repeated
  /// lookups within one query loop. Lookup failures (absent parent, SQLite
  /// error) are swallowed and negatively memoized so a missing parent never
  /// blocks the inbound notification and never re-queries.
  func enrichedReplyContext(
    _ db: Connection,
    replyToGUID: String?,
    threadOriginatorGUID: String?,
    cache: inout ReplyParentCache
  ) -> ReplyParent? {
    for candidate in [threadOriginatorGUID, replyToGUID] {
      guard let guid = candidate, !guid.isEmpty else { continue }
      if let cached = cache[guid] {
        if let parent = cached { return parent }
        continue
      }
      let result = try? resolveReplyParent(db, guid: guid)
      cache[guid] = result
      if let result { return result }
    }
    return nil
  }
}
