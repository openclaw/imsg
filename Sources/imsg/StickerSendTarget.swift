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

/// Where an attached sticker sits on its target bubble: its center as a
/// fraction of the bubble's width and height from the top-left corner, a scale
/// multiplier, and a clockwise rotation in degrees. Each value left out keeps
/// the default, a centered sticker at its natural size with no rotation.
struct StickerPlacement: Equatable {
  static let offsetRange: ClosedRange<Double> = -3...3
  static let scaleRange: ClosedRange<Double> = 0.1...4
  static let rotationRange: ClosedRange<Double> = -180...180

  let x: Double
  let y: Double
  let scale: Double
  let rotation: Double

  /// Returns nil when no value is given, so a sticker without placement sends
  /// exactly as before.
  static func resolve(
    x: Double?, y: Double?, scale: Double?, rotation: Double?, hasTarget: Bool
  ) throws -> StickerPlacement? {
    guard x != nil || y != nil || scale != nil || rotation != nil else { return nil }
    guard hasTarget else { throw StickerSendValidationError.placementWithoutTarget }
    let values: [(String, Double?, ClosedRange<Double>)] = [
      ("x", x, offsetRange), ("y", y, offsetRange), ("scale", scale, scaleRange),
      ("rotation", rotation, rotationRange),
    ]
    for (name, value, range) in values {
      if let value, !value.isFinite || !range.contains(value) {
        throw StickerSendValidationError.invalidPlacement(name: name, range: range)
      }
    }
    return StickerPlacement(x: x ?? 0.5, y: y ?? 0.5, scale: scale ?? 1, rotation: rotation ?? 0)
  }

  /// The helper takes rotation in radians, the unit Messages stores.
  var bridgeParams: [String: Any] {
    ["x": x, "y": y, "scale": scale, "rotation": rotation * .pi / 180]
  }
}

func bridgeSupportsStickerPlacement(_ status: [String: Any]) -> Bool {
  let selectors = status["selectors"] as? [String: Any]
  return selectors?["stickerPlacement"] as? Bool == true
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
  case placementWithoutTarget
  case invalidPlacement(name: String, range: ClosedRange<Double>)
  case placementUnsupported

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
    case .placementWithoutTarget:
      return "x, y, scale, and rotation require --attach-to / attach_to"
    case .invalidPlacement(let name, let range):
      let bound = { (value: Double) in
        value == value.rounded() ? String(Int(value)) : String(value)
      }
      return
        "\(name) must be a number from \(bound(range.lowerBound)) to \(bound(range.upperBound))"
    case .placementUnsupported:
      return "running bridge does not support sticker placement; "
        + "restart Messages with the current imsg bridge"
    }
  }
}
