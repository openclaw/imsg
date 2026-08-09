import Foundation
import IMsgCore

func chatPayload(
  id: Int64,
  identifier: String,
  guid: String,
  name: String,
  service: String,
  lastMessageAt: Date,
  participants: [String],
  contactName: String? = nil,
  unreadCount: Int? = nil
) -> [String: Any] {
  var payload: [String: Any] = [
    "id": id,
    "identifier": identifier,
    "guid": guid,
    "name": name,
    "service": service,
    "last_message_at": CLIISO8601.format(lastMessageAt),
    "participants": participants,
    "is_group": isGroupHandle(identifier: identifier, guid: guid),
  ]
  if let unreadCount {
    payload["unread_count"] = unreadCount
  }
  if let contactName {
    payload["contact_name"] = contactName
  }
  return payload
}

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

func reactionPayload(_ reaction: Reaction, senderName: String? = nil) -> [String: Any] {
  var payload: [String: Any] = [
    "id": reaction.rowID,
    "type": reaction.reactionType.name,
    "emoji": reaction.reactionType.emoji,
    "sender": reaction.sender,
    "is_from_me": reaction.isFromMe,
    "created_at": CLIISO8601.format(reaction.date),
  ]
  if let senderName {
    payload["sender_name"] = senderName
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
