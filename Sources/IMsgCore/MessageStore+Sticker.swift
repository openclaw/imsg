import Foundation
import SQLite

extension MessageStore {
  public func messageBelongsToChat(messageGUID: String, chatGUID: String) throws -> Bool {
    guard !messageGUID.isEmpty, !chatGUID.isEmpty else { return false }
    let candidates = Self.stickerChatTargetCandidates(chatGUID)
    guard !candidates.isEmpty else { return false }
    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
    return try withConnection { db in
      let rows = try db.prepareRowIterator(
        """
        SELECT 1 AS found
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.guid = ?
          AND (c.guid IN (\(placeholders)) OR c.chat_identifier IN (\(placeholders)))
        LIMIT 1
        """,
        bindings: [messageGUID] + candidates + candidates
      )
      return try rows.failableNext() != nil
    }
  }

  private static func stickerChatTargetCandidates(_ raw: String) -> [Binding?] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var ordered = [trimmed]
    let parts = trimmed.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 3, !parts[2].isEmpty {
      ordered.append(parts[2])
      ordered.append("any;+;\(parts[2])")
      ordered.append("any;-;\(parts[2])")
    }
    var seen = Set<String>()
    return ordered.compactMap { candidate -> Binding? in
      guard seen.insert(candidate).inserted else { return nil }
      return candidate
    }
  }
}
