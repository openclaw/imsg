import Foundation
import IMsgCore

private enum RPCSendTransport: String {
  case auto
  case bridge
  case applescript

  static func parse(_ raw: String?) throws -> RPCSendTransport {
    let value = raw?.lowercased() ?? "auto"
    guard let transport = RPCSendTransport(rawValue: value) else {
      throw RPCError.invalidParams("invalid transport")
    }
    return transport
  }
}

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

  func handleSend(params: [String: Any], id: Any?) async throws {
    try await handleSend(params: params, id: id, tracked: false)
  }

  func handleSendTracked(params: [String: Any], id: Any?) async throws {
    try await handleSend(params: params, id: id, tracked: true)
  }

  private func handleSend(params: [String: Any], id: Any?, tracked: Bool) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.replyTarget,
      [
        "to", "text", "file", "text_formatting", "textFormatting", "formatting", "service",
        "transport", "region", "allow_sms_fallback", "allowSMSFallback",
        "attempt_id",
      ]
    )
    let method = tracked ? "send.tracked" : "send"
    let params = try RPCParameters(params, method: method, supportedKeys: supportedKeys)
    let text = try params.string("text") ?? ""
    let file = try params.string("file") ?? ""
    let attemptID: String?
    if tracked {
      guard let rawAttemptID = try params.string("attempt_id"),
        let uuid = UUID(uuidString: rawAttemptID)
      else {
        throw RPCError.invalidParams("attempt_id must be a UUID")
      }
      attemptID = uuid.uuidString.lowercased()
    } else {
      guard try params.string("attempt_id") == nil else {
        throw RPCError.invalidParams("attempt_id is only supported by send.tracked")
      }
      attemptID = nil
    }
    // Optional attributed-text formatting (bold/italic/…, macOS 15+). Only the
    // IMCore bridge transport can render it; AppleScript sends stay plain.
    // Accept `text_formatting`/`textFormatting` (matching `send-rich`) plus the
    // bare `formatting` key that the OpenClaw gateway emits on its `send` calls.
    let textFormatting = try params.objectArray(
      "text_formatting", aliases: ["textFormatting", "formatting"])
    let serviceRaw = try params.string("service") ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let transport = try RPCSendTransport.parse(try params.string("transport"))
    let region = try params.string("region") ?? "US"
    let requestedSMSFallback =
      try params.boolean("allow_sms_fallback", aliases: ["allowSMSFallback"]) ?? true
    let requestContacts =
      (contactResolver as? ContactResolver)?.resolver(region: region) ?? contactResolver
    let selectedMessageGuid = try params.string(
      "reply_to", aliases: ["replyTo", "reply_to_guid", "message_guid"]
    ).flatMap { $0.isEmpty ? nil : $0 }
    let rawInput = try params.recipientOrChatTarget()
    let rawRecipient = rawInput.recipient
    let recipient: String
    do {
      recipient =
        rawInput.hasChatTarget || rawRecipient.isEmpty
        ? rawRecipient
        : try ChatTargetResolver.resolveRecipientName(rawRecipient, contacts: requestContacts)
    } catch {
      throw RPCError.invalidParams(error.localizedDescription)
    }
    let input = ChatTargetInput(
      recipient: recipient,
      chatID: rawInput.chatID,
      chatIdentifier: rawInput.chatIdentifier,
      chatGUID: rawInput.chatGUID
    )

    if text.isEmpty && file.isEmpty {
      throw RPCError.invalidParams("text or file is required")
    }
    if tracked && (text.isEmpty || !file.isEmpty) {
      throw RPCError.invalidParams("send.tracked supports exactly one text message")
    }
    if tracked && transport == .applescript {
      throw RPCError.invalidParams("send.tracked requires bridge transport")
    }

    let database: RPCDatabaseResources?
    if tracked {
      let required = try await databaseResources.require()
      if let attemptID, try required.store.messageSendStatus(guid: attemptID) != nil {
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: BridgeAction.sendMessage.rawValue,
          detail: "attempt_id already identifies a message; choose a new UUID"
        )
      }
      database = required
    } else if input.chatID != nil {
      database = try await databaseResources.require()
    } else {
      database = await databaseResources.available()
    }

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try database?.store.chatInfo(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }
    var effectiveService = service
    if service == .auto && !input.hasChatTarget && !input.recipient.isEmpty {
      switch (try? database?.store.preferredService(forHandle: input.recipient, region: region))
        ?? .unknown
      {
      case .imessage, .unknown:
        effectiveService = .auto
      case .sms:
        effectiveService = .sms
      }
    }

    let directChatInfo =
      input.hasChatTarget
      ? nil
      : try database.map {
        try ChatTargetResolver.existingDirectChat(
          store: $0.store,
          recipient: input.recipient,
          service: effectiveService,
          includeAnyForSMS: service == .auto && effectiveService == .sms
        )
      } ?? nil

    let allowSMSFallback =
      requestedSMSFallback
      && service == .auto
      && !input.hasChatTarget
      && !input.recipient.isEmpty
      && !text.isEmpty
      && file.isEmpty

    let options = MessageSendOptions(
      recipient: input.recipient,
      text: text,
      attachmentPath: file,
      service: effectiveService,
      region: region,
      chatIdentifier: input.hasChatTarget ? resolvedTarget.chatIdentifier : "",
      chatGUID: input.hasChatTarget ? resolvedTarget.chatGUID : (directChatInfo?.guid ?? ""),
      allowSMSFallback: allowSMSFallback,
      directParticipantTarget: ChatTargetResolver.directParticipantTarget(
        store: database?.store, resolvedTarget: resolvedTarget, directChatInfo: directChatInfo)
    )
    let sentAt = Date()

    if let bridgeChatGUID = bridgeChatGUID(
      resolvedTarget: resolvedTarget, directChatInfo: directChatInfo),
      transport != .applescript,
      transport == .bridge || isBridgeReady()
    {
      do {
        let data = try await sendViaBridge(
          chatGUID: bridgeChatGUID,
          text: text,
          file: file,
          selectedMessageGuid: selectedMessageGuid,
          textFormatting: textFormatting,
          clientMessageGuid: attemptID
        )
        var result: [String: Any] = ["ok": true, "transport": "bridge"]
        if let guid = data["messageGuid"] as? String, !guid.isEmpty {
          result["guid"] = guid
          result["message_id"] = guid
        }
        if let chatGuid = data["chatGuid"] as? String, !chatGuid.isEmpty {
          result["chat_guid"] = chatGuid
        }
        if let service = data["service"] as? String, !service.isEmpty {
          result["service"] = service
        }
        if let attemptID {
          result["attempt_id"] = attemptID
        }
        respond(id: id, result: result)
        return
      } catch let failure as DeliveryFailure {
        if tracked || transport == .bridge || selectedMessageGuid != nil || !failure.retrySafe {
          throw failure
        }
      } catch let err as RPCError {
        if tracked || transport == .bridge || selectedMessageGuid != nil {
          throw err
        }
      } catch {
        throw RPCError.internalError(String(describing: error))
      }
    } else if tracked || transport == .bridge {
      throw RPCError.invalidParams("bridge transport requires an existing chat target")
    } else if selectedMessageGuid != nil {
      throw RPCError.invalidParams(
        "reply_to requires bridge transport; AppleScript fallback cannot send threaded replies"
      )
    }

    try sendMessage(options)

    let sentMessage: Message?
    let verificationChatID =
      input.chatID
      ?? resolvedTarget.preferredIdentifier.flatMap {
        try? database?.store.chatInfo(matchingTarget: $0)?.id
      }
      ?? directChatInfo?.id
    if let database, input.hasChatTarget || !text.isEmpty {
      sentMessage = try await SentMessageVerifier.verifyAppleScriptSend(
        store: database.store,
        options: options,
        chatID: verificationChatID,
        sentAt: sentAt,
        resolve: resolveSentMessage
      )
    } else {
      sentMessage = nil
    }
    var result: [String: Any] = ["ok": true, "transport": "applescript"]
    if let sentMessage {
      result["id"] = sentMessage.rowID
      if !sentMessage.guid.isEmpty {
        result["guid"] = sentMessage.guid
        result["message_id"] = sentMessage.guid
      }
    }
    var responseChatInfo: ChatInfo?
    if let sentMessage, let database {
      responseChatInfo = try? database.store.chatInfo(chatID: sentMessage.chatID)
    }
    if responseChatInfo == nil, let verificationChatID, let database {
      responseChatInfo = try? database.store.chatInfo(chatID: verificationChatID)
    }
    if responseChatInfo == nil {
      responseChatInfo = directChatInfo
    }
    if let chatInfo = responseChatInfo {
      if !chatInfo.guid.isEmpty {
        result["chat_guid"] = chatInfo.guid
      }
      if !chatInfo.service.isEmpty {
        result["service"] = chatInfo.service
      }
    }
    if result["chat_guid"] == nil {
      let resolvedChatGUID =
        !resolvedTarget.chatGUID.isEmpty ? resolvedTarget.chatGUID : (directChatInfo?.guid ?? "")
      if !resolvedChatGUID.isEmpty {
        result["chat_guid"] = resolvedChatGUID
      }
    }
    if result["service"] == nil,
      let directService = directChatInfo?.service, !directService.isEmpty
    {
      result["service"] = directService
    }
    respond(id: id, result: result)
  }

  /// `typing` — start/stop the local-user typing indicator. Mirrors the
  /// `imsg typing` CLI surface (which is purely a wrapper over `TypingIndicator`)
  /// so callers that talk to `imsg rpc` over JSON-RPC have parity with the CLI.
  func handleTyping(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget, ["to", "typing", "service"])
    let params = try RPCParameters(params, method: "typing", supportedKeys: supportedKeys)
    let isTyping = try params.boolean("typing") ?? true
    let serviceRaw = try params.string("service") ?? "imessage"
    let input = try params.recipientOrChatTarget()
    let database: RPCDatabaseResources?
    if input.chatID != nil {
      database = try await databaseResources.require()
    } else {
      database = await databaseResources.available()
    }
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try database?.store.chatInfo(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let identifier: String
    if let preferred = resolvedTarget.preferredIdentifier {
      identifier = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      do {
        guard let service = MessageService(rawValue: serviceRaw.lowercased()) else {
          throw RPCError.invalidParams(serviceRaw)
        }
        if let database,
          let info = try ChatTargetResolver.existingDirectChat(
            store: database.store, recipient: input.recipient, service: service),
          let preferred = bridgeChatGUID(resolvedTarget: nil, directChatInfo: info)
        {
          identifier = preferred
        } else {
          identifier = try ChatTargetResolver.directTypingIdentifier(
            recipient: input.recipient,
            serviceRaw: serviceRaw,
            invalidServiceError: { RPCError.invalidParams($0) }
          )
        }
      } catch let err as RPCError {
        throw err
      }
    }
    if isTyping {
      try startTyping(identifier)
    } else {
      try stopTyping(identifier)
    }
    respond(id: id, result: ["ok": true])
  }

  /// `read` — mark all messages in a chat as read on this device, which also
  /// fires a read-receipt to the sender if the chat has receipts enabled.
  func handleRead(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["to"])
    let params = try RPCParameters(params, method: "read", supportedKeys: supportedKeys)
    let input = try params.recipientOrChatTarget()
    let database: RPCDatabaseResources?
    if input.chatID != nil {
      database = try await databaseResources.require()
    } else {
      database = await databaseResources.available()
    }
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try database?.store.chatInfo(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let handle: String
    if let preferred = resolvedTarget.preferredIdentifier {
      handle = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      handle = input.recipient
    }
    try await markAsRead(handle)
    respond(id: id, result: ["ok": true])
  }

  private func bridgeChatGUID(
    resolvedTarget: ResolvedChatTarget?,
    directChatInfo: ChatInfo?
  ) -> String? {
    if let guid = resolvedTarget?.chatGUID, !guid.isEmpty { return guid }
    if let identifier = resolvedTarget?.chatIdentifier, !identifier.isEmpty { return identifier }
    if let guid = directChatInfo?.guid, !guid.isEmpty { return guid }
    if let identifier = directChatInfo?.identifier, !identifier.isEmpty { return identifier }
    return nil
  }

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
