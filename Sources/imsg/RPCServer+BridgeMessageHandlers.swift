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
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "filePath": try stageAttachment((file as NSString).expandingTildeInPath),
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

  func handlePollSend(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.replyTarget,
      [
        "question", "options", "option", "creator_handle", "creatorHandle", "comment",
        "suppress_comment", "suppressComment",
      ]
    )
    let params = try RPCParameters(params, method: "poll.send", supportedKeys: supportedKeys)
    guard let question = try params.string("question"), !question.isEmpty else {
      throw RPCError.invalidParams("question is required")
    }
    let options = try rpcPollOptionsParam(params)
    let creatorHandle = try params.string("creator_handle", aliases: ["creatorHandle"])
    let reply = try params.string(
      "reply_to", aliases: ["replyTo", "reply_to_guid", "message_guid"])
    let commentValue = try params.string("comment")
    let suppressComment =
      try params.boolean("suppress_comment", aliases: ["suppressComment"]) ?? false
    if commentValue != nil, suppressComment {
      throw RPCError.invalidParams("comment cannot be combined with suppress_comment: true")
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "question": question,
      "options": options,
    ]
    if let creatorHandle, !creatorHandle.isEmpty {
      bridgeParams["creatorHandle"] = creatorHandle
    }
    if let reply, !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }

    let data = try await invokeBridge(action: .sendPoll, params: bridgeParams)
    var result: [String: Any] = [
      "ok": true,
      "event": "imessage.poll.created",
    ]
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
    if let poll = data["poll"] as? [String: Any] {
      result["poll"] = poll
    }

    // Messages never renders the poll title on the balloon, so send the question
    // (or an explicit `comment` override) as a PLAIN caption message right after
    // the poll — matching how the native "comment or Send" field renders. Not a
    // threaded reply: native poll comments carry no thread metadata, so a reply
    // would decorate the balloon with a connector line. Outbound (from_me) rows
    // are cached and never re-processed, so no poll<->comment link is needed.
    // Callers pass only `question`; the caption appears for free and the agent
    // needs no knowledge of this. Best-effort: the poll already succeeded, so a
    // comment failure must not fail the RPC.
    let comment = commentValue.flatMap { $0.isEmpty ? nil : $0 } ?? question
    var poisonAfterResponse: DeliveryFailure?
    let pollGuid = (data["messageGuid"] as? String) ?? ""
    let pollDescription = pollGuid.isEmpty ? "queued poll" : "poll \(pollGuid)"
    if suppressComment || comment.isEmpty {
      result["comment"] = PollCaptionStatus.suppressed
    } else {
      do {
        let captionData = try await invokeBridge(
          action: .sendMessage,
          params: [
            "chatGuid": chatGUID,
            "message": comment,
          ])
        // The bridge acknowledging the send is not proof the caption row
        // reached the chat, and an accepted-but-absent caption leaves exactly
        // the question-less balloon this status exists to expose.
        let captionGUID = (captionData["messageGuid"] as? String) ?? ""
        let outcome = await captionVerifier(
          captionGUID, chatGUID, await databaseResources.available()?.store)
        result["comment"] = PollCaptionStatus.status(
          forVerification: outcome, messageGUID: captionGUID)
        if outcome == .unknown {
          FileHandle.standardError.write(
            Data(
              "[imsg] poll.send: caption \(captionGUID) delivery was not verified in \(chatGUID); automatic retry is unsafe\n"
                .utf8))
        }
      } catch let failure as DeliveryFailure {
        if failure.disposition == .stillInFlight {
          poisonAfterResponse = failure
        }
        result["comment"] = PollCaptionStatus.failed(failure)
        let failureState = failure.retrySafe ? "failed before dispatch" : "delivery unresolved"
        FileHandle.standardError.write(
          Data(
            "[imsg] poll.send: comment echo \(failureState) for \(pollDescription): \(failure)\n"
              .utf8))
      } catch {
        result["comment"] = PollCaptionStatus.failed(error)
        FileHandle.standardError.write(
          Data("[imsg] poll.send: comment echo failed for \(pollDescription): \(error)\n".utf8))
      }
    }
    // `ok` stays true when only the caption failed: the poll balloon really did
    // land, and a caller that treats this as a failed send would re-send and
    // duplicate it. `comment` reports confirmed failure separately from an
    // outcome that is still unknown.
    respond(id: id, result: result)
    if let poisonAfterResponse {
      throw RPCMutationPoisonSignal(failure: poisonAfterResponse)
    }
  }

  func handlePollVote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(
      params: params, id: id, remove: false, method: "poll.vote")
  }

  func handlePollUnvote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(
      params: params, id: id, remove: true, method: "poll.unvote")
  }

  private func handlePollVoteMutation(
    params rawParams: [String: Any],
    id: Any?,
    remove: Bool,
    method: String
  ) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      [
        "poll_guid", "pollGuid", "poll_message_guid", "message_guid", "message_id",
        "option_id", "optionId", "optionIdentifier", "option_index", "optionIndex", "option",
      ]
    )
    let params = try RPCParameters(rawParams, method: method, supportedKeys: supportedKeys)
    guard
      let pollGUID = try params.string(
        "poll_guid",
        aliases: ["pollGuid", "poll_message_guid", "message_guid", "message_id"]),
      !pollGUID.isEmpty
    else {
      throw RPCError.invalidParams("poll_guid is required")
    }
    let directOptionID = try params.string(
      "option_id", aliases: ["optionId", "optionIdentifier"]
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    let optionIndex = try params.integer("option_index", aliases: ["optionIndex"])
    let optionText = try params.string("option")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let selectors = [
      directOptionID?.isEmpty == false,
      optionIndex != nil,
      optionText?.isEmpty == false,
    ]
    guard selectors.contains(true) else {
      throw RPCError.invalidParams("one of option_id, option_index, or option is required")
    }
    guard selectors.filter({ $0 }).count == 1 else {
      throw RPCError.invalidParams("choose exactly one of option_id, option_index, or option")
    }
    // Resolve every selector against decoded options, so callers cannot vote
    // against an arbitrary non-poll GUID or supply caller-trusted option text.
    let database = try await databaseResources.require()
    let chatGUID = try await resolveChatGUIDParam(params)
    let pollOptions = try database.store.pollOptions(guid: pollGUID)
    guard !pollOptions.isEmpty else {
      throw RPCError.invalidParams("poll \(pollGUID) not found or not decodable")
    }

    let matchedOption: MessagePollOption
    if let directOptionID, !directOptionID.isEmpty {
      guard let option = pollOptions.first(where: { $0.id == directOptionID }) else {
        throw RPCError.invalidParams(
          "option_id \(directOptionID) is not an option of poll \(pollGUID)")
      }
      matchedOption = option
    } else if let optionIndex {
      guard optionIndex >= 1, optionIndex <= pollOptions.count else {
        throw RPCError.invalidParams(
          "option_index \(optionIndex) out of range (1...\(pollOptions.count))")
      }
      matchedOption = pollOptions[optionIndex - 1]
    } else {
      let text = optionText ?? ""
      guard
        let option = pollOptions.first(where: {
          $0.text.caseInsensitiveCompare(text) == .orderedSame
        })
      else {
        let available = pollOptions.map(\.text).joined(separator: ", ")
        throw RPCError.invalidParams("option \"\(text)\" (available: \(available))")
      }
      matchedOption = option
    }
    let optionID = matchedOption.id
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      // Native votes associate to the bare poll GUID (strip a leading p:<part>/).
      "pollMessageGuid": barePollGuid(pollGUID),
      "optionIdentifier": optionID,
    ]
    if !matchedOption.text.isEmpty {
      bridgeParams["optionText"] = matchedOption.text
    }
    if remove {
      let selectedOptionIDs = try database.store.pollSelectedOptionIDs(guid: pollGUID)
      guard selectedOptionIDs.contains(optionID) else {
        throw RPCError.invalidParams("option_id \(optionID) is not currently selected")
      }
      bridgeParams["remainingOptionIdentifiers"] = selectedOptionIDs.filter { $0 != optionID }
    }

    let data = try await invokeBridge(
      action: remove ? .sendPollUnvote : .sendPollVote,
      params: bridgeParams)
    var result: [String: Any] = [
      "ok": true,
      "event": remove ? "imessage.poll.unvoted" : "imessage.poll.voted",
      // Callers use the resolved option to suppress a redundant text reply that
      // just restates the vote, so return it alongside the poll linkage.
      "poll_guid": barePollGuid(pollGUID),
      "option_id": matchedOption.id,
      "option_text": matchedOption.text,
    ]
    if let remaining = bridgeParams["remainingOptionIdentifiers"] as? [String] {
      result["remaining_option_ids"] = remaining
    }
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
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
