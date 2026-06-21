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
    let limit = intParam(params["limit"]) ?? 20
    let chats = try store.listChats(limit: max(limit, 1))
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(chats.count)

    for chat in chats {
      let info = try await cache.info(chatID: chat.id)
      let participants = try await cache.participants(chatID: chat.id)
      let identifier = info?.identifier ?? chat.identifier
      let guid = info?.guid ?? ""
      let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
      let service = info?.service ?? chat.service
      let contactName =
        isGroupHandle(identifier: identifier, guid: guid)
        ? nil : contactResolver.displayName(for: identifier)
      payloads.append(
        chatPayload(
          id: chat.id,
          identifier: identifier,
          guid: guid,
          name: name,
          service: service,
          lastMessageAt: chat.lastMessageAt,
          participants: participants,
          contactName: contactName
        ))
    }

    respond(id: id, result: ["chats": payloads])
  }

  func handleMessagesHistory(id: Any?, params: [String: Any]) async throws {
    guard let chatID = int64Param(params["chat_id"]) else {
      throw RPCError.invalidParams("chat_id is required")
    }
    let limit = intParam(params["limit"]) ?? 50
    let participants = stringArrayParam(params["participants"])
    let startISO = stringParam(params["start"])
    let endISO = stringParam(params["end"])
    let includeAttachments = boolParam(params["attachments"]) ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: boolParam(params["convert_attachments"]) ?? false)
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let filtered = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)

    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(filtered.count)
    for message in filtered {
      let payload = try await buildMessagePayload(
        store: store,
        cache: cache,
        message: message,
        includeAttachments: includeAttachments,
        includeReactions: true,
        attachmentOptions: attachmentOptions,
        contactResolver: contactResolver
      )
      payloads.append(payload)
    }

    respond(id: id, result: ["messages": payloads])
  }

  func handleWatchSubscribe(id: Any?, params: [String: Any]) async throws {
    let chatID = int64Param(params["chat_id"])
    let sinceRowID = int64Param(params["since_rowid"])
    let participants = stringArrayParam(params["participants"])
    let startISO = stringParam(params["start"])
    let endISO = stringParam(params["end"])
    let includeAttachments = boolParam(params["attachments"]) ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: boolParam(params["convert_attachments"]) ?? false)
    let includeReactions = boolParam(params["include_reactions"]) ?? false
    let debounceInterval = try watchDebounceIntervalParam(params)
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      includeReactions: includeReactions
    )
    let subID = await subscriptions.allocateID()
    let localStore = store
    let localWatcher = watcher
    let localCache = cache
    let localWriter = output
    let localFilter = filter
    let localChatID = chatID
    let localSinceRowID = sinceRowID
    let localConfig = config
    let localIncludeAttachments = includeAttachments
    let localAttachmentOptions = attachmentOptions
    let localIncludeReactions = includeReactions
    let localContactResolver = contactResolver
    let task = Task {
      do {
        for try await message in localWatcher.stream(
          chatID: localChatID,
          sinceRowID: localSinceRowID,
          configuration: localConfig
        ) {
          if Task.isCancelled { return }
          if !localFilter.allows(message) { continue }
          let payload = try await buildMessagePayload(
            store: localStore,
            cache: localCache,
            message: message,
            includeAttachments: localIncludeAttachments,
            includeReactions: localIncludeReactions,
            attachmentOptions: localAttachmentOptions,
            contactResolver: localContactResolver
          )
          localWriter.sendNotification(
            method: "message",
            params: ["subscription": subID, "message": payload]
          )
        }
      } catch {
        localWriter.sendNotification(
          method: "error",
          params: [
            "subscription": subID,
            "error": ["message": String(describing: error)],
          ]
        )
      }
    }
    await subscriptions.insert(task, for: subID)
    respond(id: id, result: ["subscription": subID])
  }

  func handleWatchUnsubscribe(id: Any?, params: [String: Any]) async throws {
    guard let subID = intParam(params["subscription"]) else {
      throw RPCError.invalidParams("subscription is required")
    }
    if let task = await subscriptions.remove(subID) {
      task.cancel()
    }
    respond(id: id, result: ["ok": true])
  }

  func handleSend(params: [String: Any], id: Any?) async throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    // Optional attributed-text formatting (bold/italic/…, macOS 15+). Only the
    // IMCore bridge transport can render it; AppleScript sends stay plain.
    // Accept `text_formatting`/`textFormatting` (matching `send-rich`) plus the
    // bare `formatting` key that the OpenClaw gateway emits on its `send` calls.
    let textFormatting =
      params["text_formatting"] ?? params["textFormatting"] ?? params["formatting"]
    let serviceRaw = stringParam(params["service"]) ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let transport = try RPCSendTransport.parse(stringParam(params["transport"]))
    let region = stringParam(params["region"]) ?? "US"
    let rawRecipient = stringParam(params["to"]) ?? ""
    let rawInput = ChatTargetInput(
      recipient: rawRecipient,
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: rawInput,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required for direct sends")
    )
    let recipient: String
    do {
      recipient =
        rawInput.hasChatTarget || rawRecipient.isEmpty
        ? rawRecipient
        : try ChatTargetResolver.resolveRecipientName(rawRecipient, contacts: contactResolver)
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

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }
    var effectiveService = service
    if service == .auto && !input.hasChatTarget && !input.recipient.isEmpty {
      switch (try? store.preferredService(forHandle: input.recipient, region: region)) ?? .unknown {
      case .imessage, .unknown:
        effectiveService = .auto
      case .sms:
        effectiveService = .sms
      }
    }

    let directChatInfo =
      input.hasChatTarget
      ? nil
      : try resolveDirectChatInfo(
        recipient: input.recipient,
        service: effectiveService,
        includeAnyForSMS: service == .auto && effectiveService == .sms
      )

    let allowSMSFallback =
      service == .auto
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
      chatIdentifier: resolvedTarget.chatIdentifier,
      chatGUID: resolvedTarget.chatGUID,
      allowSMSFallback: allowSMSFallback
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
          textFormatting: textFormatting
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
        respond(id: id, result: result)
        return
      } catch let err as RPCError {
        if transport == .bridge {
          throw err
        }
      } catch {
        if transport == .bridge {
          throw RPCError.internalError(String(describing: error))
        }
      }
    } else if transport == .bridge {
      throw RPCError.invalidParams("bridge transport requires an existing chat target")
    }

    try sendMessage(options)

    let verificationChatID =
      input.chatID
      ?? resolvedTarget.preferredIdentifier.flatMap { try? store.chatInfo(matchingTarget: $0)?.id }
      ?? directChatInfo?.id
    let sentMessage = try? await resolveSentMessage(store, options, verificationChatID, sentAt)
    if sentMessage == nil {
      try SentMessageVerifier.throwIfMisroutedChatSend(
        store: store,
        options: options,
        sentAt: sentAt
      )
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
    if let sentMessage {
      responseChatInfo = try? await cache.info(chatID: sentMessage.chatID)
    }
    if responseChatInfo == nil, let verificationChatID {
      responseChatInfo = try? await cache.info(chatID: verificationChatID)
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

  func handleHandlesCheck(params: [String: Any], id: Any?) async throws {
    let address = stringParam(params["address"]) ?? ""
    guard !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }

    let aliasType =
      (stringParam(params["alias_type"]) ?? (address.contains("@") ? "email" : "phone"))
      .lowercased()
    guard aliasType == "phone" || aliasType == "email" else {
      throw RPCError.invalidParams("alias_type must be phone or email")
    }

    let service = stringParam(params["service"]) ?? "iMessage"
    guard service.caseInsensitiveCompare("iMessage") == .orderedSame else {
      throw RPCError.invalidParams("handles.check only supports service iMessage")
    }

    if !isBridgeReady() {
      throw RPCError.internalError(
        "handles.check requires bridge transport (Messages.app must be injected)"
      )
    }

    let data = try await bridgeInvoker(
      .checkImessageAvailability,
      [
        "address": address,
        "aliasType": aliasType,
      ])

    var result: [String: Any] = ["ok": true]
    result["address"] = data["address"] as? String ?? address
    result["alias_type"] = data["alias_type"] as? String ?? aliasType
    if let destination = data["destination"] as? String, !destination.isEmpty {
      result["destination"] = destination
    }
    if let idStatus = intParam(data["id_status"]) {
      result["id_status"] = idStatus
    }
    if let available = boolParam(data["available"]) {
      result["available"] = available
    }
    result["service"] = "iMessage"
    respond(id: id, result: result)
  }

  /// `typing` — start/stop the local-user typing indicator. Mirrors the
  /// `imsg typing` CLI surface (which is purely a wrapper over `TypingIndicator`)
  /// so callers that talk to `imsg rpc` over JSON-RPC have parity with the CLI.
  func handleTyping(params: [String: Any], id: Any?) async throws {
    let isTyping = boolParam(params["typing"]) ?? true
    let serviceRaw = stringParam(params["service"]) ?? "imessage"
    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required")
    )
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
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
        if let info = try resolveDirectChatInfo(recipient: input.recipient, service: service),
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
    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required")
    )
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
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
    try await IMCoreBridge.shared.markAsRead(handle: handle)
    respond(id: id, result: ["ok": true])
  }

  private func resolveDirectChatInfo(
    recipient: String,
    service: MessageService,
    includeAnyForSMS: Bool = false
  ) throws -> ChatInfo? {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates = ChatTargetResolver.directChatCandidates(recipient: recipient, service: service)
    let requireExactMatch = includeAnyForSMS
    if includeAnyForSMS, !trimmed.isEmpty {
      candidates = ["SMS;-;\(trimmed)", "any;-;\(trimmed)", "any;+;\(trimmed)"]
    }
    for candidate in candidates {
      let info: ChatInfo?
      if requireExactMatch {
        info = try store.chatInfo(matchingExactTarget: candidate)
      } else {
        info = try store.chatInfo(matchingTarget: candidate)
      }
      if let info {
        return info
      }
    }
    return nil
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

  private func sendViaBridge(
    chatGUID: String,
    text: String,
    file: String,
    textFormatting: Any? = nil
  ) async throws -> [String: Any] {
    if !file.isEmpty {
      guard text.isEmpty else {
        throw RPCError.invalidParams("bridge transport does not support text and file together")
      }
      let stagedFile = try stageAttachment(file)
      return try await bridgeInvoker(
        .sendAttachment,
        ["chatGuid": chatGUID, "filePath": stagedFile, "isAudioMessage": false]
      )
    }
    var messageParams: [String: Any] = ["chatGuid": chatGUID, "message": text]
    if let textFormatting {
      messageParams["textFormatting"] = textFormatting
    }
    return try await bridgeInvoker(.sendMessage, messageParams)
  }
}

func buildMessagePayload(
  store: MessageStore,
  cache: ChatCache,
  message: Message,
  includeAttachments: Bool,
  includeReactions: Bool,
  prefetchedAttachments: [AttachmentMeta]? = nil,
  prefetchedReactions: [Reaction]? = nil,
  attachmentOptions: AttachmentQueryOptions = .default,
  contactResolver: any ContactResolving = NoOpContactResolver()
) async throws -> [String: Any] {
  let chatInfo = try await cache.info(chatID: message.chatID)
  let participants = try await cache.participants(chatID: message.chatID)
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
