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

public struct Chat: Sendable, Equatable {
  public let id: Int64
  public let identifier: String
  public let name: String
  public let service: String
  public let lastMessageAt: Date
  public let accountID: String?
  public let accountLogin: String?
  public let lastAddressedHandle: String?

  public init(
    id: Int64,
    identifier: String,
    name: String,
    service: String,
    lastMessageAt: Date,
    accountID: String? = nil,
    accountLogin: String? = nil,
    lastAddressedHandle: String? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.name = name
    self.service = service
    self.lastMessageAt = lastMessageAt
    self.accountID = accountID
    self.accountLogin = accountLogin
    self.lastAddressedHandle = lastAddressedHandle
  }
}

public struct ChatInfo: Sendable, Equatable {
  public let id: Int64
  public let identifier: String
  public let guid: String
  public let name: String
  public let service: String
  public let accountID: String?
  public let accountLogin: String?
  public let lastAddressedHandle: String?

  public init(
    id: Int64,
    identifier: String,
    guid: String,
    name: String,
    service: String,
    accountID: String? = nil,
    accountLogin: String? = nil,
    lastAddressedHandle: String? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.guid = guid
    self.name = name
    self.service = service
    self.accountID = accountID
    self.accountLogin = accountLogin
    self.lastAddressedHandle = lastAddressedHandle
  }
}

public struct Message: Sendable, Equatable {
  public struct RoutingMetadata: Sendable, Equatable {
    public let replyToGUID: String?
    public let threadOriginatorGUID: String?
    public let threadOriginatorPart: String?
    public let destinationCallerID: String?
    public let replyToText: String?
    public let replyToSender: String?

    public init(
      replyToGUID: String? = nil,
      threadOriginatorGUID: String? = nil,
      threadOriginatorPart: String? = nil,
      destinationCallerID: String? = nil,
      replyToText: String? = nil,
      replyToSender: String? = nil
    ) {
      self.replyToGUID = replyToGUID
      self.threadOriginatorGUID = threadOriginatorGUID
      self.threadOriginatorPart = threadOriginatorPart
      self.destinationCallerID = destinationCallerID
      self.replyToText = replyToText
      self.replyToSender = replyToSender
    }
  }

  public struct ReactionMetadata: Sendable, Equatable {
    public let isReaction: Bool
    public let reactionType: ReactionType?
    public let isReactionAdd: Bool?
    public let reactedToGUID: String?

    public init(
      isReaction: Bool = false,
      reactionType: ReactionType? = nil,
      isReactionAdd: Bool? = nil,
      reactedToGUID: String? = nil
    ) {
      self.isReaction = isReaction
      self.reactionType = reactionType
      self.isReactionAdd = isReactionAdd
      self.reactedToGUID = reactedToGUID
    }
  }

  public let rowID: Int64
  public let chatID: Int64
  public let guid: String
  public let replyToGUID: String?
  public let threadOriginatorGUID: String?
  public let threadOriginatorPart: String?
  /// Text of the message this one replies to (Threader reply or non-reaction
  /// association). Resolved by joining `replyToGUID` or `threadOriginatorGUID`
  /// back to the parent row; nil when no parent exists or it is no longer
  /// in chat.db.
  public let replyToText: String?
  /// Sender handle (`h.id`) of the message this one replies to.
  public let replyToSender: String?
  public let sender: String
  public let text: String
  public let date: Date
  public let isFromMe: Bool
  public let service: String
  public let handleID: Int64?
  public let attachmentsCount: Int
  /// The destination_caller_id from the database. For messages where is_from_me is true,
  /// this can help distinguish between messages actually sent by the local user vs
  /// messages received on a secondary phone number registered with the same Apple ID.
  public let destinationCallerID: String?
  /// Raw Messages `message.balloon_bundle_id`, when present. Consumers can use
  /// Apple-owned bundle identifiers such as URLBalloonProvider as structural
  /// metadata instead of inferring message shape from user text.
  public let balloonBundleID: String?
  /// Native Messages Polls metadata when the row is a Polls extension balloon
  /// or a Polls vote update.
  public let poll: MessagePollEvent?
  /// Metadata for an Apple URL preview balloon row that was folded into this
  /// message. The message itself still uses the originating text row's id,
  /// guid, text, and timestamp.
  public let urlPreview: URLPreviewMetadata?

  // Reaction metadata (populated when message is a reaction event)
  /// Whether this message is a reaction event (tapback add/remove)
  public let isReaction: Bool
  /// The type of reaction (only set when isReaction is true)
  public let reactionType: ReactionType?
  /// Whether this is adding (true) or removing (false) a reaction (only set when isReaction is true)
  public let isReactionAdd: Bool?
  /// The GUID of the message being reacted to (only set when isReaction is true)
  public let reactedToGUID: String?

  public init(
    rowID: Int64,
    chatID: Int64,
    sender: String,
    text: String,
    date: Date,
    isFromMe: Bool,
    service: String,
    handleID: Int64?,
    attachmentsCount: Int,
    guid: String = "",
    routing: RoutingMetadata = RoutingMetadata(),
    balloonBundleID: String? = nil,
    urlPreview: URLPreviewMetadata? = nil,
    reaction: ReactionMetadata = ReactionMetadata(),
    poll: MessagePollEvent? = nil
  ) {
    self.rowID = rowID
    self.chatID = chatID
    self.guid = guid
    self.replyToGUID = routing.replyToGUID
    self.threadOriginatorGUID = routing.threadOriginatorGUID
    self.threadOriginatorPart = routing.threadOriginatorPart
    self.replyToText = routing.replyToText
    self.replyToSender = routing.replyToSender
    self.sender = sender
    self.text = text
    self.date = date
    self.isFromMe = isFromMe
    self.service = service
    self.handleID = handleID
    self.attachmentsCount = attachmentsCount
    self.destinationCallerID = routing.destinationCallerID
    self.balloonBundleID = balloonBundleID
    self.poll = poll
    self.urlPreview = urlPreview
    self.isReaction = reaction.isReaction
    self.reactionType = reaction.reactionType
    self.isReactionAdd = reaction.isReactionAdd
    self.reactedToGUID = reaction.reactedToGUID
  }

  public init(
    rowID: Int64,
    chatID: Int64,
    sender: String,
    text: String,
    date: Date,
    isFromMe: Bool,
    service: String,
    handleID: Int64?,
    attachmentsCount: Int,
    guid: String = "",
    replyToGUID: String? = nil,
    threadOriginatorGUID: String? = nil,
    threadOriginatorPart: String? = nil,
    destinationCallerID: String? = nil,
    balloonBundleID: String? = nil,
    urlPreview: URLPreviewMetadata? = nil,
    replyToText: String? = nil,
    replyToSender: String? = nil,
    isReaction: Bool = false,
    reactionType: ReactionType? = nil,
    isReactionAdd: Bool? = nil,
    reactedToGUID: String? = nil,
    poll: MessagePollEvent? = nil
  ) {
    self.init(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: text,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      routing: RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        threadOriginatorPart: threadOriginatorPart,
        destinationCallerID: destinationCallerID,
        replyToText: replyToText,
        replyToSender: replyToSender
      ),
      balloonBundleID: balloonBundleID,
      urlPreview: urlPreview,
      reaction: ReactionMetadata(
        isReaction: isReaction,
        reactionType: reactionType,
        isReactionAdd: isReactionAdd,
        reactedToGUID: reactedToGUID
      ),
      poll: poll
    )
  }

}

public struct AttachmentMeta: Sendable, Equatable {
  public let filename: String
  public let transferName: String
  public let uti: String
  public let mimeType: String
  public let totalBytes: Int64
  public let isSticker: Bool
  public let originalPath: String
  public let convertedPath: String?
  public let convertedMimeType: String?
  public let missing: Bool

  public init(
    filename: String,
    transferName: String,
    uti: String,
    mimeType: String,
    totalBytes: Int64,
    isSticker: Bool,
    originalPath: String,
    convertedPath: String? = nil,
    convertedMimeType: String? = nil,
    missing: Bool
  ) {
    self.filename = filename
    self.transferName = transferName
    self.uti = uti
    self.mimeType = mimeType
    self.totalBytes = totalBytes
    self.isSticker = isSticker
    self.originalPath = originalPath
    self.convertedPath = convertedPath
    self.convertedMimeType = convertedMimeType
    self.missing = missing
  }
}

public struct AttachmentQueryOptions: Sendable, Equatable {
  public static let `default` = AttachmentQueryOptions()

  public let convertUnsupported: Bool

  public init(convertUnsupported: Bool = false) {
    self.convertUnsupported = convertUnsupported
  }
}
