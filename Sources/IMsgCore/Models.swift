import Foundation

public struct Chat: Sendable, Equatable {
  public let id: Int64
  public let identifier: String
  public let name: String
  public let service: String
  public let lastMessageAt: Date
  public let accountID: String?
  public let accountLogin: String?
  public let lastAddressedHandle: String?
  /// Inbound unread row count, or nil when the database has no read state.
  public let unreadCount: Int?

  public init(
    id: Int64,
    identifier: String,
    name: String,
    service: String,
    lastMessageAt: Date,
    accountID: String? = nil,
    accountLogin: String? = nil,
    lastAddressedHandle: String? = nil,
    unreadCount: Int? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.name = name
    self.service = service
    self.lastMessageAt = lastMessageAt
    self.accountID = accountID
    self.accountLogin = accountLogin
    self.lastAddressedHandle = lastAddressedHandle
    self.unreadCount = unreadCount
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
  public enum MutationEvent: String, Sendable, Equatable {
    case edited
    case unsent
  }

  /// Current database mutation timestamps. Nil on unchanged rows or older schemas.
  public let editedAt: Date?
  public let unsentAt: Date?
  /// Set only for a live update to a previously observed row.
  public var mutationEvent: MutationEvent?

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
  /// Local read state for inbound messages, when available.
  public let isRead: Bool?
  /// Local read timestamp for inbound messages, when available.
  public let dateRead: Date?

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
    poll: MessagePollEvent? = nil,
    isRead: Bool? = nil,
    dateRead: Date? = nil,
    editedAt: Date? = nil,
    unsentAt: Date? = nil,
    mutationEvent: MutationEvent? = nil
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
    self.isRead = isRead
    self.dateRead = dateRead
    self.editedAt = editedAt
    self.unsentAt = unsentAt
    self.mutationEvent = mutationEvent
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
    poll: MessagePollEvent? = nil,
    isRead: Bool? = nil,
    dateRead: Date? = nil,
    editedAt: Date? = nil,
    unsentAt: Date? = nil,
    mutationEvent: MutationEvent? = nil
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
      poll: poll,
      isRead: isRead,
      dateRead: dateRead,
      editedAt: editedAt,
      unsentAt: unsentAt,
      mutationEvent: mutationEvent
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
