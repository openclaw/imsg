import Foundation
import IMsgCore

extension RPCServer {
  func handleSendRich(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.replyTarget,
      RPCParameterKeys.partIndex,
      [
        "text", "message", "file", "path", "url", "dd_scan", "ddScan", "effect_id",
        "effectId", "effect", "subject", "text_formatting", "textFormatting",
      ]
    )
    let params = try RPCParameters(params, method: "send.rich", supportedKeys: supportedKeys)
    if params.contains("url") {
      try await handleSendRichLink(params: params, id: id)
      return
    }
    let text = try params.string("text", aliases: ["message"]) ?? ""
    let file = try params.string("file", aliases: ["path"]) ?? ""
    if params.contains("file") || params.contains("path") {
      guard !file.isEmpty else {
        throw RPCError.invalidParams("file must be a non-empty string")
      }
    }
    let partIndex = try params.integer("part_index", aliases: ["partIndex"]) ?? 0
    let ddScan = try params.boolean("dd_scan", aliases: ["ddScan"]) ?? true
    let effect = try params.string("effect_id", aliases: ["effectId", "effect"])
    let subject = try params.string("subject")
    let reply = try params.string(
      "reply_to", aliases: ["replyTo", "reply_to_guid", "message_guid"])
    let formatting = try params.objectArray("text_formatting", aliases: ["textFormatting"])
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "message": text,
      "partIndex": partIndex,
      "ddScan": ddScan,
    ]
    if let effect, !effect.isEmpty {
      bridgeParams["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject, !subject.isEmpty {
      bridgeParams["subject"] = subject
    }
    if let reply, !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }
    if let formatting {
      bridgeParams["textFormatting"] = formatting
    }

    if file.isEmpty {
      let sentAt = Date()
      let data = try await invokeBridge(action: .sendMessage, params: bridgeParams)
      let database = await databaseResources.available()
      let chatInfo = try bridgeResponseChatInfo(
        params: params, chatGUID: chatGUID, database: database)
      var result = await SendRichCommand.enrichedSentMessageResponse(
        data,
        chat: chatGUID,
        text: text,
        sentAt: sentAt,
        store: database?.store,
        chatInfo: chatInfo,
        resolveSentMessage: resolveSentMessage
      )
      result["ok"] = true
      respond(id: id, result: result)
      return
    }

    let verification = try await bridgeSendVerificationBaseline()
    try await requireRichAttachmentCapability(
      requiresMetadata: !text.isEmpty || effect?.isEmpty == false || subject?.isEmpty == false
        || reply?.isEmpty == false || partIndex != 0 || formatting != nil
    )
    do {
      bridgeParams["filePath"] = try stageAttachment((file as NSString).expandingTildeInPath)
    } catch {
      throw DeliveryFailure(
        disposition: .notStarted,
        transport: .bridgeV2,
        operation: BridgeAction.sendAttachment.rawValue,
        detail: "The attachment could not be staged before bridge dispatch."
      )
    }
    bridgeParams["isAudioMessage"] = false
    let data = try await invokeBridge(action: .sendAttachment, params: bridgeParams)
    var result = try await verifiedBridgeSendResponse(
      data,
      params: params,
      chatGUID: chatGUID,
      action: .sendAttachment,
      database: verification.database,
      baselineRowID: verification.rowID
    )
    result["ok"] = true
    respond(id: id, result: result)
  }

  private func handleSendRichLink(params: RPCParameters, id: Any?) async throws {
    let incompatibleKeys = [
      "text", "message", "dd_scan", "ddScan", "effect_id", "effectId", "effect", "subject",
      "reply_to", "replyTo", "reply_to_guid", "message_guid", "part_index", "partIndex",
      "text_formatting", "textFormatting", "file", "path",
    ]
    if let unsupported = incompatibleKeys.first(where: params.contains) {
      throw RPCError.invalidParams("\(unsupported) is not supported with url")
    }
    guard let rawURL = try params.string("url") else {
      throw RPCError.invalidParams("url is required")
    }

    let database = try await databaseResources.require()
    let chatInfo = try await strictRichLinkChatInfo(params, database: database)
    let chatGUID = chatInfo.guid
    let status = try await invokeBridge(action: .status, params: [:])
    guard bridgeSupportsRichLinks(status) else {
      throw RPCError.internalError(
        "running bridge does not support rich links; restart Messages with the current imsg bridge"
      )
    }

    let prepared: PreparedRichLinkPreview
    do {
      prepared = try await prepareRichLink(rawURL)
    } catch let error as RichLinkPreparationError {
      throw RPCError.invalidParams(error.localizedDescription)
    }
    defer { prepared.removeStagedImage() }

    let sentAt = Date()
    let data: [String: Any]
    do {
      data = try await invokeBridge(
        action: .sendRichLink,
        params: [
          "chatGuid": chatGUID,
          "message": prepared.originalURL,
          "partIndex": 0,
          "ddScan": true,
          "richLinkPreview": prepared.bridgePayload,
        ]
      )
    } catch {
      throw error
    }
    var result = await SendRichCommand.enrichedSentMessageResponse(
      data,
      chat: chatGUID,
      text: prepared.originalURL,
      sentAt: sentAt,
      store: database.store,
      chatInfo: chatInfo,
      resolveSentMessage: resolveSentMessage
    )
    result["ok"] = true
    respond(id: id, result: result)
  }

  func handleSendAttachment(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.replyTarget,
      RPCParameterKeys.partIndex,
      ["file", "path", "audio", "is_audio", "as_voice"]
    )
    let params = try RPCParameters(
      params, method: "send.attachment", supportedKeys: supportedKeys)
    guard let file = try params.string("file", aliases: ["path"]), !file.isEmpty else {
      throw RPCError.invalidParams("file is required")
    }
    let audio = try params.boolean("audio", aliases: ["is_audio", "as_voice"]) ?? false
    let reply = try params.string(
      "reply_to", aliases: ["replyTo", "reply_to_guid", "message_guid"])
    let partIndex = try params.integer("part_index", aliases: ["partIndex"])
    if let partIndex {
      guard partIndex >= 0 else {
        throw RPCError.invalidParams("part_index must be a non-negative integer")
      }
      guard reply?.isEmpty == false else {
        throw RPCError.invalidParams("part_index requires reply_to")
      }
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    let stagedFile = try (audio ? stageAudioAttachment : stageAttachment)(
      (file as NSString).expandingTildeInPath)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "filePath": stagedFile,
      "isAudioMessage": audio,
    ]
    if let reply, !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }
    if let partIndex {
      bridgeParams["partIndex"] = partIndex
    }
    let data = try await invokeBridge(action: .sendAttachment, params: bridgeParams)
    let database = await databaseResources.available()
    let chatInfo = try bridgeResponseChatInfo(
      params: params, chatGUID: chatGUID, database: database)
    var result = await SendRichCommand.enrichedSentMessageResponse(
      data,
      chat: chatGUID,
      text: "",
      sentAt: Date(),
      store: database?.store,
      chatInfo: chatInfo,
      resolveSentMessage: resolveSentMessage
    )
    result["ok"] = true
    respond(id: id, result: result)
  }

  func handleTapback(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.messageTarget,
      RPCParameterKeys.partIndex,
      ["reaction", "kind", "emoji", "remove"]
    )
    let params = try RPCParameters(params, method: "tapback", supportedKeys: supportedKeys)
    guard let messageGUID = try rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    let rawReaction = try params.string("reaction", aliases: ["kind", "emoji"]) ?? ""
    let remove = try params.boolean("remove") ?? false
    let partIndex = try params.integer("part_index", aliases: ["partIndex"]) ?? 0
    let chatGUID = try await resolveChatGUIDParam(params)
    let reactionType = try normalizeBridgeReactionType(
      rawReaction,
      remove: remove
    )
    _ = try await invokeBridge(
      action: .sendReaction,
      params: [
        "chatGuid": chatGUID,
        "selectedMessageGuid": messageGUID,
        "reactionType": reactionType,
        "partIndex": partIndex,
      ]
    )
    respond(id: id, result: ["ok": true, "reaction": reactionType])
  }

  func handleMessageEdit(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.messageTarget,
      RPCParameterKeys.partIndex,
      [
        "text", "new_text", "newText", "edited_message", "backwards_compatibility_message",
        "backwardsCompatibilityMessage", "bc_text", "bcText",
      ]
    )
    let params = try RPCParameters(params, method: "message.edit", supportedKeys: supportedKeys)
    guard let messageGUID = try rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    guard
      let text = try params.string(
        "text", aliases: ["new_text", "newText", "edited_message"]),
      !text.isEmpty
    else {
      throw RPCError.invalidParams("text is required")
    }
    let compatibilityText =
      try params.string(
        "backwards_compatibility_message",
        aliases: ["backwardsCompatibilityMessage", "bc_text", "bcText"]
      ) ?? text
    let partIndex = try params.integer("part_index", aliases: ["partIndex"]) ?? 0
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(
      action: .editMessage,
      params: [
        "chatGuid": chatGUID,
        "messageGuid": messageGUID,
        "editedMessage": text,
        "backwardsCompatibilityMessage": compatibilityText,
        "partIndex": partIndex,
      ]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleMessageUnsend(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(
      action: .unsendMessage,
      params: params,
      id: id,
      includePartIndex: true,
      method: "message.unsend"
    )
  }

  func handleMessageDelete(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(
      action: .deleteMessage, params: params, id: id, method: "message.delete")
  }

  func handleMessageNotifyAnyways(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(
      action: .notifyAnyways, params: params, id: id, method: "message.notifyAnyways")
  }

  func handleNamePhotoStatus(params: [String: Any], id: Any?) async throws {
    let params = try RPCParameters(
      params,
      method: "contacts.shouldShareContact",
      supportedKeys: RPCParameterKeys.chatTarget
    )
    let chatGUID = try await resolveChatGUIDParam(params)
    let data = try await invokeBridge(
      action: .shouldOfferNicknameSharing,
      params: ["chatGuid": chatGUID]
    )
    respond(id: id, result: data.merging(["ok": true]) { current, _ in current })
  }

  func handleNamePhotoShare(params: [String: Any], id: Any?) async throws {
    let params = try RPCParameters(
      params,
      method: "contacts.shareContactCard",
      supportedKeys: RPCParameterKeys.chatTarget
    )
    let chatGUID = try await resolveChatGUIDParam(params)
    let data = try await invokeBridge(action: .shareNickname, params: ["chatGuid": chatGUID])
    respond(id: id, result: data.merging(["ok": true]) { current, _ in current })
  }

  private func invokeMessageGUIDBridgeAction(
    action: BridgeAction,
    params: [String: Any],
    id: Any?,
    includePartIndex: Bool = false,
    method: String
  ) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.messageTarget,
      includePartIndex ? RPCParameterKeys.partIndex : []
    )
    let params = try RPCParameters(params, method: method, supportedKeys: supportedKeys)
    guard let messageGUID = try rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    let partIndex =
      includePartIndex ? (try params.integer("part_index", aliases: ["partIndex"]) ?? 0) : nil
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "messageGuid": messageGUID,
    ]
    if let partIndex {
      bridgeParams["partIndex"] = partIndex
    }
    _ = try await invokeBridge(action: action, params: bridgeParams)
    respond(id: id, result: ["ok": true])
  }
}
