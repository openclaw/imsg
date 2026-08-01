import Foundation
import SQLite

enum URLPreviewCoalescingFallback {
  case suppress
  case replace(Message)
}

extension MessageStore {
  static let urlPreviewBalloonBundleID = "com.apple.messages.URLBalloonProvider"
  private static let urlPreviewCoalescingWindow: TimeInterval = 5

  func coalesceURLPreviewMessages(
    _ messages: [Message],
    validateExistingCoalescence: ((Message, Message) throws -> Bool)? = nil,
    fallbackForUnmatchedPreview: ((Message) throws -> URLPreviewCoalescingFallback?)? = nil,
    fallbackReplacementUsed: (() -> Void)? = nil
  ) throws -> [Message] {
    guard !messages.isEmpty else { return messages }

    let rowOrdered = messages.enumerated().sorted { lhs, rhs in
      lhs.element.rowID < rhs.element.rowID
    }
    var replacements: [Int: Message] = [:]
    var suppressed = Set<Int>()

    for position in rowOrdered.indices {
      let preview = rowOrdered[position]
      guard isURLPreviewBalloon(preview.element), !suppressed.contains(preview.offset) else {
        continue
      }

      if let candidate = previousMessageInSameChat(
        rowOrdered,
        before: position,
        suppressed: suppressed
      ) {
        let textMessage = replacements[candidate.offset] ?? candidate.element
        let isValidExistingMatch =
          try validateExistingCoalescence?(textMessage, preview.element) ?? true
        if isValidExistingMatch
          && canCoalesceURLPreview(textMessage: textMessage, previewMessage: preview.element)
        {
          replacements[candidate.offset] = textMessage.withURLPreview(
            urlPreviewMetadata(from: preview.element)
          )
          suppressed.insert(preview.offset)
          continue
        }
      }

      guard let fallback = try fallbackForUnmatchedPreview?(preview.element) else {
        continue
      }
      switch fallback {
      case .suppress:
        suppressed.insert(preview.offset)
      case .replace(let textMessage):
        fallbackReplacementUsed?()
        replacements[preview.offset] = textMessage.withURLPreview(
          urlPreviewMetadata(from: preview.element)
        )
      }
    }

    var result: [Message] = []
    result.reserveCapacity(messages.count - suppressed.count)
    for (index, message) in messages.enumerated() where !suppressed.contains(index) {
      result.append(replacements[index] ?? message)
    }
    return result
  }

  func canCoalesceURLPreview(textMessage: Message, previewMessage: Message) -> Bool {
    guard isURLPreviewBalloon(previewMessage) else { return false }
    guard textMessage.balloonBundleID == nil else { return false }
    guard textMessage.chatID == previewMessage.chatID else { return false }
    guard textMessage.isFromMe == previewMessage.isFromMe else { return false }
    guard textMessage.sender == previewMessage.sender else { return false }
    if let textHandle = textMessage.handleID, let previewHandle = previewMessage.handleID,
      textHandle != previewHandle
    {
      return false
    }
    guard previewMessage.rowID > textMessage.rowID else { return false }
    let delta = previewMessage.date.timeIntervalSince(textMessage.date)
    guard delta >= 0 && delta <= MessageStore.urlPreviewCoalescingWindow else {
      return false
    }
    return textMessageContainsPreviewURL(
      textMessage.text,
      previewText: previewMessage.text
    )
  }

  func isURLPreviewBalloon(_ message: Message) -> Bool {
    message.balloonBundleID == MessageStore.urlPreviewBalloonBundleID
  }

  func pageVisibleMessages(_ messages: [Message], db: Connection) throws -> [Message] {
    try coalesceURLPreviewMessages(
      messages,
      validateExistingCoalescence: { text, preview in
        try self.precedingTextMessageForURLPreview(preview, db: db)?.rowID == text.rowID
      },
      fallbackForUnmatchedPreview: { preview in
        guard try self.precedingTextMessageForURLPreview(preview, db: db) != nil else {
          return nil
        }
        return .suppress
      }
    )
  }

  func enrichMessagesWithTrailingURLPreviews(
    _ messages: [Message],
    afterRowID: Int64,
    db: Connection
  ) throws -> [Message] {
    guard schema.hasBalloonBundleIDColumn, !messages.isEmpty else { return messages }

    var enriched = messages
    let indexByRowID = Dictionary(
      uniqueKeysWithValues: messages.enumerated().map { ($0.element.rowID, $0.offset) }
    )
    var lastBaseByChatID: [Int64: Message] = [:]
    for message in messages where !isURLPreviewBalloon(message) && !message.isReaction {
      lastBaseByChatID[message.chatID] = message
    }
    let pageBases = lastBaseByChatID.values.sorted { $0.rowID < $1.rowID }
    guard !pageBases.isEmpty else { return messages }

    let reactionFilter =
      schema.hasReactionColumns
      ? """
       AND (
         next.associated_message_type IS NULL
         OR next.associated_message_type < 2000
         OR next.associated_message_type > 3006
       )
      """
      : ""
    let selection = MessageRowSelection(store: self, includeChatID: true)

    // Keep each VALUES block below SQLite's historical 999-variable limit.
    for start in stride(from: 0, to: pageBases.count, by: 400) {
      let end = min(start + 400, pageBases.count)
      let batch = pageBases[start..<end]
      let values = Array(repeating: "(?, ?)", count: batch.count).joined(separator: ", ")
      let sql = """
        WITH page_base(parent_rowid, chat_id) AS (VALUES \(values)),
        preview_window AS (
          SELECT page_base.*,
                 (
                   SELECT next.ROWID
                   FROM message next
                   JOIN chat_message_join next_cmj ON next.ROWID = next_cmj.message_id
                   WHERE next.ROWID > ?
                     AND next_cmj.chat_id = page_base.chat_id
                     AND COALESCE(next.balloon_bundle_id, '') <> ?
                     \(reactionFilter)
                   ORDER BY next_cmj.message_id ASC
                   LIMIT 1
                 ) AS boundary_rowid
          FROM page_base
        )
        SELECT \(selection.selectList),
               preview_window.parent_rowid AS preview_parent_rowid
        FROM preview_window
        JOIN chat_message_join cmj ON cmj.chat_id = preview_window.chat_id
        JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > ?
          AND (preview_window.boundary_rowid IS NULL OR m.ROWID < preview_window.boundary_rowid)
          AND m.balloon_bundle_id = ?
        ORDER BY m.ROWID ASC
        """
      var bindings: [Binding?] = []
      for message in batch {
        bindings.append(message.rowID)
        bindings.append(message.chatID)
      }
      bindings.append(afterRowID)
      bindings.append(MessageStore.urlPreviewBalloonBundleID)
      bindings.append(afterRowID)
      bindings.append(MessageStore.urlPreviewBalloonBundleID)

      var parentCache: ReplyParentCache = [:]
      var pollOptionCache = PollOptionTextCache()
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      while let row = try rows.failableNext() {
        let parentRowID = try int64Value(row, "preview_parent_rowid")
        guard
          let parentRowID,
          let index = indexByRowID[parentRowID]
        else {
          continue
        }
        let decoded = try decodeMessageRow(
          row,
          columns: selection.columns,
          fallbackChatID: enriched[index].chatID
        )
        let preview = try message(
          from: decoded,
          db,
          parentCache: &parentCache,
          pollOptionCache: &pollOptionCache
        )
        guard
          try precedingTextMessageForURLPreview(preview, db: db)?.rowID == parentRowID
        else {
          continue
        }
        enriched[index] = enriched[index].withURLPreview(urlPreviewMetadata(from: preview))
      }
    }
    return enriched
  }

  private func previousMessageInSameChat(
    _ chronological: [(offset: Int, element: Message)],
    before position: Int,
    suppressed: Set<Int>
  ) -> (offset: Int, element: Message)? {
    guard position > 0 else { return nil }
    let preview = chronological[position].element
    for index in stride(from: position - 1, through: 0, by: -1) {
      let candidate = chronological[index]
      guard !suppressed.contains(candidate.offset) else { continue }
      guard !candidate.element.isReaction else { continue }
      if candidate.element.chatID == preview.chatID {
        return candidate
      }
    }
    return nil
  }

  private func textMessageContainsPreviewURL(_ text: String, previewText: String) -> Bool {
    let preview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isLikelyURLPreviewText(preview) else { return false }
    let candidates = [
      preview,
      preview.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
    ]
    return candidates.contains { candidate in
      !candidate.isEmpty && text.range(of: candidate, options: [.caseInsensitive]) != nil
    }
  }

  private func isLikelyURLPreviewText(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return lowercased.hasPrefix("http://")
      || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("www.")
  }

  private func urlPreviewMetadata(from message: Message) -> Message.URLPreviewMetadata {
    Message.URLPreviewMetadata(
      rowID: message.rowID,
      guid: message.guid,
      balloonBundleID: message.balloonBundleID ?? MessageStore.urlPreviewBalloonBundleID,
      date: message.date
    )
  }
}
