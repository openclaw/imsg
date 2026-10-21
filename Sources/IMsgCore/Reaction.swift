import Foundation

/// The type of reaction on an iMessage.
/// Values correspond to the `associated_message_type` column in the Messages database.
/// Standard tapbacks are 2000-2005, custom emoji reactions are 2006.
public enum ReactionType: Sendable, Equatable, Hashable {
  case love
  case like
  case dislike
  case laugh
  case emphasis
  case question
  case custom(String)

  /// Initialize from the database associated_message_type value
  /// For custom emojis (2006), pass the emoji string extracted from the message text
  public init?(rawValue: Int, customEmoji: String? = nil) {
    switch rawValue {
    case 2000: self = .love
    case 2001: self = .like
    case 2002: self = .dislike
    case 2003: self = .laugh
    case 2004: self = .emphasis
    case 2005: self = .question
    case 2006:
      guard let emoji = customEmoji else { return nil }
      self = .custom(emoji)
    default: return nil
    }
  }

  /// Returns the reaction type for a removal (values 3000-3006)
  public static func fromRemoval(_ value: Int, customEmoji: String? = nil) -> ReactionType? {
    return ReactionType(rawValue: value - 1000, customEmoji: customEmoji)
  }

  /// Whether this associated_message_type represents adding a reaction (2000-2006)
  public static func isReactionAdd(_ value: Int) -> Bool {
    return value >= 2000 && value <= 2006
  }

  /// Whether this associated_message_type represents removing a reaction (3000-3006)
  public static func isReactionRemove(_ value: Int) -> Bool {
    return value >= 3000 && value <= 3006
  }

  /// Whether this associated_message_type represents any reaction add/remove
  public static func isReaction(_ value: Int) -> Bool {
    return isReactionAdd(value) || isReactionRemove(value)
  }

  /// Human-readable name for the reaction
  public var name: String {
    switch self {
    case .love: return "love"
    case .like: return "like"
    case .dislike: return "dislike"
    case .laugh: return "laugh"
    case .emphasis: return "emphasis"
    case .question: return "question"
    case .custom: return "custom"
    }
  }

  /// Emoji representation of the reaction
  public var emoji: String {
    switch self {
    case .love: return "❤️"
    case .like: return "👍"
    case .dislike: return "👎"
    case .laugh: return "😂"
    case .emphasis: return "‼️"
    case .question: return "❓"
    case .custom(let emoji): return emoji
    }
  }

  /// Associated message type for adding this reaction (2000-2006).
  public var associatedMessageType: Int {
    switch self {
    case .love: return 2000
    case .like: return 2001
    case .dislike: return 2002
    case .laugh: return 2003
    case .emphasis: return 2004
    case .question: return 2005
    case .custom: return 2006
    }
  }

  /// Associated message type for removing this reaction (3000-3006).
  public var removalAssociatedMessageType: Int {
    return associatedMessageType + 1000
  }

  public var isCustom: Bool {
    if case .custom = self {
      return true
    }
    return false
  }

  public static func parse(_ value: String) -> ReactionType? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    switch lower {
    case "love", "heart":
      return .love
    case "like", "thumbsup", "thumbs-up":
      return .like
    case "dislike", "thumbsdown", "thumbs-down":
      return .dislike
    case "laugh", "haha", "lol":
      return .laugh
    case "emphasis", "emphasize", "exclaim", "exclamation":
      return .emphasis
    case "question", "questionmark", "question-mark":
      return .question
    default:
      break
    }
    switch trimmed {
    case "❤️", "❤":
      return .love
    case "👍":
      return .like
    case "👎":
      return .dislike
    case "😂":
      return .laugh
    case "‼️", "‼":
      return .emphasis
    case "❓", "?":
      return .question
    default:
      break
    }
    if containsEmoji(trimmed) {
      return .custom(trimmed)
    }
    return nil
  }

  private static func containsEmoji(_ value: String) -> Bool {
    for scalar in value.unicodeScalars {
      if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
        return true
      }
    }
    return false
  }
}

/// A reaction to an iMessage.
public struct Reaction: Sendable, Equatable {
  /// The ROWID of the reaction message in the database
  public let rowID: Int64
  /// The type of reaction
  public let reactionType: ReactionType
  /// The sender of the reaction (phone number or email)
  public let sender: String
  /// Whether the reaction was sent by the current user
  public let isFromMe: Bool
  /// When the reaction was added
  public let date: Date
  /// The ROWID of the message being reacted to
  public let associatedMessageID: Int64

  public init(
    rowID: Int64,
    reactionType: ReactionType,
    sender: String,
    isFromMe: Bool,
    date: Date,
    associatedMessageID: Int64
  ) {
    self.rowID = rowID
    self.reactionType = reactionType
    self.sender = sender
    self.isFromMe = isFromMe
    self.date = date
    self.associatedMessageID = associatedMessageID
  }
}
