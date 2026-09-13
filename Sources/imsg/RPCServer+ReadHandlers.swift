import Foundation
import IMsgCore

extension RPCServer {
  func handleChatsList(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "chats.list",
      supportedKeys: ["limit", "unread_only", "unreadOnly"]
    )
    let limit = try params.integer("limit") ?? 20
    guard limit > 0 else {
      throw RPCError.invalidParams("limit must be a positive integer")
    }
    let unreadOnly = try params.boolean("unread_only", aliases: ["unreadOnly"]) ?? false
    let database = try await databaseResources.require()
    let store = database.store
    guard !unreadOnly || store.supportsUnreadState else {
      throw RPCError.invalidParams(
        "unread_only is unavailable because this Messages database has no read-state column")
    }
    let chats = try store.listChats(limit: limit, unreadOnly: unreadOnly)
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(chats.count)

    for chat in chats {
      let info = try store.chatInfo(chatID: chat.id)
      let participants = try store.participants(chatID: chat.id)
      let contactName = contactNameForChat(
        chat: chat,
        chatInfo: info,
        participants: participants,
        contacts: contactResolver
      )
      payloads.append(
        try ChatPayload(
          chat: chat,
          chatInfo: info,
          participants: participants,
          contactName: contactName
        ).asDictionary())
    }

    respond(id: id, result: ["chats": payloads])
  }

  func handleMessagesHistory(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "messages.history",
      supportedKeys: [
        "chat_id", "limit", "participants", "start", "end", "attachments",
        "convert_attachments",
      ]
    )
    guard let chatID = try params.int64("chat_id") else {
      throw RPCError.invalidParams("chat_id is required")
    }
    guard chatID > 0 else {
      throw RPCError.invalidParams("chat_id must be a positive integer")
    }
    let limit = try params.integer("limit") ?? 50
    guard limit > 0 else {
      throw RPCError.invalidParams("limit must be a positive integer")
    }
    let participants = try params.stringArray("participants") ?? []
    let startISO = try params.string("start")
    let endISO = try params.string("end")
    let includeAttachments = try params.boolean("attachments") ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: try params.boolean("convert_attachments") ?? false)
    let database = try await databaseResources.require()
    let store = database.store
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let filtered = try store.messages(chatID: chatID, limit: limit, filter: filter)
    let reactionsByMessageID = try store.reactions(for: filtered)

    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(filtered.count)
    for message in filtered {
      let payload = try buildMessagePayload(
        store: store,
        message: message,
        includeAttachments: includeAttachments,
        includeReactions: true,
        prefetchedReactions: reactionsByMessageID[message.rowID] ?? [],
        attachmentOptions: attachmentOptions,
        contactResolver: contactResolver
      )
      payloads.append(payload)
    }

    respond(id: id, result: ["messages": payloads])
  }

}
