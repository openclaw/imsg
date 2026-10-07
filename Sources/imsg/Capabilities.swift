// The engine's capability block: the one place a client reads, in a single call, to learn what this build can do
// and which build it is. A capability is named and versioned, the version being an integer that rises when the
// capability's contract changes, so a client asks for the version it needs and can reason about generations. It is
// never an adjective ("safe", "new") whose meaning a client has to trust, and the block never accumulates
// booleans. The engine's own build identity rides alongside it, the same three fields the server stamp carries:
// the release version, the commit it was built from, and the time it was built.
import Foundation

/// The engine's own build identity.
struct EngineBuildIdentity: Encodable {
  let version: String
  let commit: String
  let builtAt: String

  enum CodingKeys: String, CodingKey {
    case version
    case commit
    case builtAt = "built_at"
  }

  static var current: EngineBuildIdentity {
    EngineBuildIdentity(version: IMsgVersion.current, commit: IMsgVersion.commit, builtAt: IMsgVersion.builtAt)
  }

  var dictionary: [String: Any] { ["version": version, "commit": commit, "built_at": builtAt] }
}

/// A named, versioned feature set plus the build that reports it.
struct EngineCapabilities: Encodable {
  let engine: EngineBuildIdentity
  let features: [String: Int]

  /// The name a client reads for arbitrary emoji reactions, and the version it must ask for.
  static let tapbackEmojiName = "tapback.emoji"

  /// The version tracks the shape of the API, and advertising it means this build supports that shape. Version 2 is
  /// where the bridge sends an arbitrary emoji as itself. A client asks for the version it needs and denies anything
  /// older: an older version, or a build that predates this block and advertises no version at all, does not support
  /// the pattern, so an arbitrary emoji is refused in place, never attempted and never folded onto a classic kind.
  static let tapbackEmojiVersion = 2

  static func current(emojiTapbackSend: Bool) -> EngineCapabilities {
    var features: [String: Int] = [:]
    if emojiTapbackSend { features[tapbackEmojiName] = tapbackEmojiVersion }
    return EngineCapabilities(engine: .current, features: features)
  }

  var dictionary: [String: Any] { ["engine": engine.dictionary, "features": features] }
}
