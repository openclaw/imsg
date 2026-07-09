import Foundation
import IMsgCore

struct ChatPayload: Codable {
  let id: Int64
  let name: String
  let identifier: String
  let service: String
  let lastMessageAt: String
  let guid: String?
  let displayName: String?
  let contactName: String?
  let isGroup: Bool
  let participants: [String]?
  let accountID: String?
  let accountLogin: String?
  let lastAddressedHandle: String?
  let unreadCount: Int?

  init(
    chat: Chat, chatInfo: ChatInfo? = nil, participants: [String]? = nil, contactName: String? = nil
  ) {
    let identifier = chatInfo?.identifier ?? chat.identifier
    let guid = chatInfo?.guid ?? ""
    self.id = chat.id
    self.name = chat.name
    self.identifier = identifier
    self.service = chatInfo?.service ?? chat.service
    self.lastMessageAt = CLIISO8601.format(chat.lastMessageAt)
    self.guid = guid.isEmpty ? nil : guid
    self.displayName = chatInfo?.name
    self.contactName = contactName
    self.isGroup = isGroupHandle(identifier: identifier, guid: guid)
    self.participants = participants
    self.accountID = chatInfo?.accountID ?? chat.accountID
    self.accountLogin = chatInfo?.accountLogin ?? chat.accountLogin
    self.lastAddressedHandle = chatInfo?.lastAddressedHandle ?? chat.lastAddressedHandle
    self.unreadCount = chat.unreadCount
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case identifier
    case service
    case lastMessageAt = "last_message_at"
    case guid
    case displayName = "display_name"
    case contactName = "contact_name"
    case isGroup = "is_group"
    case participants
    case accountID = "account_id"
    case accountLogin = "account_login"
    case lastAddressedHandle = "last_addressed_handle"
    case unreadCount = "unread_count"
  }
}

struct MessagePayload: Codable {
  struct URLPreviewPayload: Codable {
    let id: Int64
    let guid: String
    let balloonBundleID: String
    let createdAt: String

    init(preview: Message.URLPreviewMetadata) {
      self.id = preview.rowID
      self.guid = preview.guid
      self.balloonBundleID = preview.balloonBundleID
      self.createdAt = CLIISO8601.format(preview.date)
    }

    enum CodingKeys: String, CodingKey {
      case id
      case guid
      case balloonBundleID = "balloon_bundle_id"
      case createdAt = "created_at"
    }
  }

  let id: Int64
  let chatID: Int64
  let guid: String
  let replyToGUID: String?
  let threadOriginatorGUID: String?
  let threadOriginatorPart: String?
  /// Text of the message this one replies to, when the inbound message is a
  /// Threader reply or a non-reaction association and the parent row is
  /// resolvable in chat.db.
  let replyToText: String?
  /// Sender handle of the parent message resolved alongside `replyToText`.
  let replyToSender: String?
  let sender: String
  let senderName: String?
  let isFromMe: Bool
  let text: String
  let createdAt: String
  let attachments: [AttachmentPayload]
  let reactions: [ReactionPayload]
  /// The destination_caller_id from the database. For messages where is_from_me is true,
  /// this can help distinguish between messages actually sent by the local user vs
  /// messages received on a secondary phone number registered with the same Apple ID.
  let destinationCallerID: String?
  let balloonBundleID: String?
  let urlPreview: URLPreviewPayload?
  let poll: MessagePollEvent?

  // Reaction event metadata (populated when this message is a reaction event)
  let isReaction: Bool?
  let reactionType: String?
  let reactionEmoji: String?
  let isReactionAdd: Bool?
  let reactedToGUID: String?
  let isRead: Bool?
  let dateRead: String?

  init(
    message: Message,
    attachments: [AttachmentMeta],
    reactions: [Reaction] = [],
    senderName: String? = nil,
    reactionSenderNames: [Int64: String] = [:]
  ) {
    self.id = message.rowID
    self.chatID = message.chatID
    self.guid = message.guid
    self.replyToGUID = message.replyToGUID
    self.threadOriginatorGUID = message.threadOriginatorGUID
    self.threadOriginatorPart = message.threadOriginatorPart
    self.replyToText = message.replyToText
    self.replyToSender = message.replyToSender
    self.sender = message.sender
    self.senderName = senderName
    self.isFromMe = message.isFromMe
    self.text = message.text
    self.createdAt = CLIISO8601.format(message.date)
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map {
      ReactionPayload(reaction: $0, senderName: reactionSenderNames[$0.rowID])
    }
    self.destinationCallerID = message.destinationCallerID
    self.balloonBundleID = message.balloonBundleID
    self.urlPreview = message.urlPreview.map { URLPreviewPayload(preview: $0) }
    self.poll = message.poll
    if message.isFromMe {
      self.isRead = nil
      self.dateRead = nil
    } else {
      self.isRead = message.isRead
      self.dateRead =
        message.isRead == true
        ? message.dateRead.map { CLIISO8601.format($0) }
        : nil
    }

    // Reaction event metadata
    if message.isReaction {
      self.isReaction = true
      self.reactionType = message.reactionType?.name
      self.reactionEmoji = message.reactionType?.emoji
      self.isReactionAdd = message.isReactionAdd
      self.reactedToGUID = message.reactedToGUID
    } else {
      self.isReaction = nil
      self.reactionType = nil
      self.reactionEmoji = nil
      self.isReactionAdd = nil
      self.reactedToGUID = nil
    }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case chatID = "chat_id"
    case guid
    case replyToGUID = "reply_to_guid"
    case threadOriginatorGUID = "thread_originator_guid"
    case threadOriginatorPart = "thread_originator_part"
    case replyToText = "reply_to_text"
    case replyToSender = "reply_to_sender"
    case sender
    case senderName = "sender_name"
    case isFromMe = "is_from_me"
    case text
    case createdAt = "created_at"
    case attachments
    case reactions
    case destinationCallerID = "destination_caller_id"
    case balloonBundleID = "balloon_bundle_id"
    case urlPreview = "url_preview"
    case poll
    case isReaction = "is_reaction"
    case reactionType = "reaction_type"
    case reactionEmoji = "reaction_emoji"
    case isReactionAdd = "is_reaction_add"
    case reactedToGUID = "reacted_to_guid"
    case isRead = "is_read"
    case dateRead = "date_read"
  }
}

extension MessagePayload {
  func asDictionary() throws -> [String: Any] {
    let data = try MessagePayload.encoder.encode(self)
    let json = try JSONSerialization.jsonObject(with: data)
    return (json as? [String: Any]) ?? [:]
  }

  private static let encoder: JSONEncoder = {
    JSONEncoder()
  }()
}

struct ReactionPayload: Codable {
  let id: Int64
  let type: String
  let emoji: String
  let sender: String
  let senderName: String?
  let isFromMe: Bool
  let createdAt: String

  init(reaction: Reaction, senderName: String? = nil) {
    self.id = reaction.rowID
    self.type = reaction.reactionType.name
    self.emoji = reaction.reactionType.emoji
    self.sender = reaction.sender
    self.senderName = senderName
    self.isFromMe = reaction.isFromMe
    self.createdAt = CLIISO8601.format(reaction.date)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case emoji
    case sender
    case senderName = "sender_name"
    case isFromMe = "is_from_me"
    case createdAt = "created_at"
  }
}

struct GroupPayload: Codable {
  let id: Int64
  let identifier: String
  let guid: String
  let name: String
  let service: String
  let isGroup: Bool
  let participants: [String]
  let accountID: String?
  let accountLogin: String?
  let lastAddressedHandle: String?

  init(chatInfo: ChatInfo, participants: [String]) {
    self.id = chatInfo.id
    self.identifier = chatInfo.identifier
    self.guid = chatInfo.guid
    self.name = chatInfo.name
    self.service = chatInfo.service
    self.isGroup = isGroupHandle(identifier: chatInfo.identifier, guid: chatInfo.guid)
    self.participants = participants
    self.accountID = chatInfo.accountID
    self.accountLogin = chatInfo.accountLogin
    self.lastAddressedHandle = chatInfo.lastAddressedHandle
  }

  enum CodingKeys: String, CodingKey {
    case id
    case identifier
    case guid
    case name
    case service
    case isGroup = "is_group"
    case participants
    case accountID = "account_id"
    case accountLogin = "account_login"
    case lastAddressedHandle = "last_addressed_handle"
  }
}

struct AttachmentPayload: Codable {
  let filename: String
  let transferName: String
  let uti: String
  let mimeType: String
  let totalBytes: Int64
  let isSticker: Bool
  let originalPath: String
  let convertedPath: String?
  let convertedMimeType: String?
  let missing: Bool

  init(meta: AttachmentMeta) {
    self.filename = meta.filename
    self.transferName = meta.transferName
    self.uti = meta.uti
    self.mimeType = meta.mimeType
    self.totalBytes = meta.totalBytes
    self.isSticker = meta.isSticker
    self.originalPath = meta.originalPath
    self.convertedPath = meta.convertedPath
    self.convertedMimeType = meta.convertedMimeType
    self.missing = meta.missing
  }

  enum CodingKeys: String, CodingKey {
    case filename = "filename"
    case transferName = "transfer_name"
    case uti = "uti"
    case mimeType = "mime_type"
    case totalBytes = "total_bytes"
    case isSticker = "is_sticker"
    case originalPath = "original_path"
    case convertedPath = "converted_path"
    case convertedMimeType = "converted_mime_type"
    case missing = "missing"
  }
}

enum CLIISO8601 {
  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
