import Foundation
import IMsgCore

func messagePayload(
  message: Message,
  chatInfo: ChatInfo?,
  participants: [String],
  attachments: [AttachmentMeta],
  reactions: [Reaction],
  senderName: String? = nil,
  reactionSenderNames: [Int64: String] = [:]
) throws -> [String: Any] {
  let identifier = chatInfo?.identifier ?? ""
  let guid = chatInfo?.guid ?? ""
  let name = chatInfo?.name ?? ""
  let core = MessagePayload(
    message: message,
    attachments: attachments,
    reactions: reactions,
    senderName: senderName,
    reactionSenderNames: reactionSenderNames
  )
  var payload = try core.asDictionary()
  payload["chat_identifier"] = identifier
  payload["chat_guid"] = guid
  payload["chat_name"] = name
  payload["participants"] = participants
  payload["is_group"] = isGroupHandle(identifier: identifier, guid: guid)
  return payload
}

func attachmentPayload(_ meta: AttachmentMeta) -> [String: Any] {
  var payload: [String: Any] = [
    "filename": meta.filename,
    "transfer_name": meta.transferName,
    "uti": meta.uti,
    "mime_type": meta.mimeType,
    "total_bytes": meta.totalBytes,
    "is_sticker": meta.isSticker,
    "original_path": meta.originalPath,
    "missing": meta.missing,
  ]
  if let convertedPath = meta.convertedPath {
    payload["converted_path"] = convertedPath
  }
  if let convertedMimeType = meta.convertedMimeType {
    payload["converted_mime_type"] = convertedMimeType
  }
  return payload
}

func isGroupHandle(identifier: String, guid: String) -> Bool {
  return guid.contains(";+;") || identifier.contains(";+;")
}

let defaultRPCWatchDebounceInterval: TimeInterval = 0.5

func watchDebounceIntervalParam(_ params: RPCParameters) throws -> TimeInterval {
  guard let milliseconds = try params.integer("debounce_ms", aliases: ["debounceMs"])
  else {
    return defaultRPCWatchDebounceInterval
  }
  guard milliseconds >= 0 else {
    throw RPCError.invalidParams("debounce_ms must be a non-negative integer")
  }
  return Double(milliseconds) / 1000
}

func buildMessagePayload(
  store: MessageStore,
  message: Message,
  includeAttachments: Bool,
  includeReactions: Bool,
  prefetchedAttachments: [AttachmentMeta]? = nil,
  prefetchedReactions: [Reaction]? = nil,
  attachmentOptions: AttachmentQueryOptions = .default,
  contactResolver: any ContactResolving = NoOpContactResolver()
) throws -> [String: Any] {
  let chatInfo = try store.chatInfo(chatID: message.chatID)
  let participants = try store.participants(chatID: message.chatID)
  let attachments: [AttachmentMeta]
  if includeAttachments {
    attachments =
      try prefetchedAttachments ?? store.attachments(for: message.rowID, options: attachmentOptions)
  } else {
    attachments = []
  }
  let reactions: [Reaction]
  if includeReactions {
    reactions = try prefetchedReactions ?? store.reactions(for: message.rowID)
  } else {
    reactions = []
  }
  let senderName = message.isFromMe ? nil : contactResolver.displayName(for: message.sender)
  var reactionSenderNames: [Int64: String] = [:]
  for reaction in reactions where !reaction.isFromMe {
    if let name = contactResolver.displayName(for: reaction.sender) {
      reactionSenderNames[reaction.rowID] = name
    }
  }
  return try messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions,
    senderName: senderName,
    reactionSenderNames: reactionSenderNames
  )
}
