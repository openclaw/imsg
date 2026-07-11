import Foundation

struct StickerSendTarget: Equatable {
  let messageGUID: String
  let partIndex: Int

  static func resolve(rawTarget: String?, explicitPart: Int?) throws -> StickerSendTarget? {
    if let explicitPart, explicitPart < 0 {
      throw StickerSendValidationError.invalidPart(explicitPart)
    }

    guard let rawTarget else {
      if explicitPart != nil { throw StickerSendValidationError.partWithoutTarget }
      return nil
    }
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { throw StickerSendValidationError.malformedTarget(rawTarget) }

    let embedded: (part: Int, guid: String)?
    if target.hasPrefix("p:") {
      let suffix = target.dropFirst(2)
      guard let slash = suffix.firstIndex(of: "/") else {
        throw StickerSendValidationError.malformedTarget(target)
      }
      let partText = suffix[..<slash]
      guard !partText.isEmpty,
        partText.allSatisfy(\.isNumber),
        let part = Int(partText),
        part >= 0
      else {
        throw StickerSendValidationError.malformedTarget(target)
      }
      let guid = String(suffix[suffix.index(after: slash)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !guid.isEmpty, !guid.hasPrefix("p:"), !guid.contains("/") else {
        throw StickerSendValidationError.malformedTarget(target)
      }
      embedded = (part, guid)
    } else {
      guard !target.contains("/") else {
        throw StickerSendValidationError.malformedTarget(target)
      }
      embedded = nil
    }

    if let embedded, let explicitPart, embedded.part != explicitPart {
      throw StickerSendValidationError.conflictingParts(
        embedded: embedded.part,
        explicit: explicitPart
      )
    }
    return StickerSendTarget(
      messageGUID: embedded?.guid ?? target,
      partIndex: explicitPart ?? embedded?.part ?? 0
    )
  }
}

func isStickerIMessageService(_ service: String) -> Bool {
  let normalized = service.lowercased()
  return normalized == "imessage" || normalized == "imessagelite"
}

func stickerChatLookupTarget(_ target: String) -> String {
  let parts = target.split(separator: ";", omittingEmptySubsequences: false)
  guard parts.count == 3, parts[0] != "any", !parts[2].isEmpty else { return target }
  return String(parts[2])
}

func directStickerChatGUID(_ target: String) -> String? {
  let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
  let parts = trimmed.split(separator: ";", omittingEmptySubsequences: false)
  guard parts.count == 3,
    isStickerIMessageService(String(parts[0])),
    parts[1] == "-",
    !parts[2].isEmpty
  else { return nil }
  return trimmed
}

enum StickerSendValidationError: LocalizedError, CustomStringConvertible, Equatable {
  case invalidPart(Int)
  case partWithoutTarget
  case malformedTarget(String)
  case conflictingParts(embedded: Int, explicit: Int)
  case targetNotInChat
  case iMessageRequired

  var errorDescription: String? { description }

  var description: String {
    switch self {
    case .invalidPart(let part):
      return "target part must be non-negative (received \(part))"
    case .partWithoutTarget:
      return "target part requires --attach-to / attach_to"
    case .malformedTarget(let target):
      return "malformed sticker target: \(target)"
    case .conflictingParts(let embedded, let explicit):
      return "target part \(explicit) conflicts with embedded part \(embedded)"
    case .targetNotInChat:
      return "sticker target does not belong to the selected chat"
    case .iMessageRequired:
      return "stickers require an iMessage chat"
    }
  }
}
