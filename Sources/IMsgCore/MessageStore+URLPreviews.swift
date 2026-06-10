import Foundation

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
