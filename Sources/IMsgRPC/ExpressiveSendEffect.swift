import Foundation

/// Expand short expressive-send names (e.g. `invisibleink`, `confetti`) to the
/// full bundle identifiers Messages.app expects on `expressiveSendStyleID`.
/// Already-prefixed strings (anything starting with `com.apple.`) and unknown
/// names pass through untouched so the dylib can return its own error.
package enum ExpressiveSendEffect {
  /// Bubble effects render on the message bubble itself.
  static let bubbleNames: Set<String> = ["impact", "loud", "gentle", "invisibleink"]

  /// Screen effects play a full-screen animation. Map the short name to the
  /// `CK<TitleCase>Effect` token used in the bundle id.
  static let screenNames: [String: String] = [
    "confetti": "Confetti",
    "lasers": "Lasers",
    "fireworks": "Fireworks",
    "balloons": "Balloons",
    "sparkles": "Sparkles",
    "spotlight": "Spotlight",
    "echo": "Echo",
    "love": "Love",
    "celebration": "Celebration",
  ]

  package static func expand(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return raw }
    if trimmed.hasPrefix("com.apple.") { return trimmed }
    let key = trimmed.lowercased()
    if bubbleNames.contains(key) {
      return "com.apple.MobileSMS.expressivesend.\(key)"
    }
    if let token = screenNames[key] {
      return "com.apple.messages.effect.CK\(token)Effect"
    }
    return trimmed
  }
}
