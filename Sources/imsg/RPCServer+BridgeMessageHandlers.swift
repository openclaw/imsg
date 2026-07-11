import CoreFoundation
import Foundation
import IMsgCore

extension RPCServer {
  func handleSendRich(params: [String: Any], id: Any?) async throws {
    let retiredRichLinkKeys = ["link", "rich_link", "richLink", "rich_link_url"]
    if let key = retiredRichLinkKeys.first(where: { params.keys.contains($0) }) {
      throw RPCError.invalidParams("\(key) is not supported; pass url without rich-link modifiers")
    }
    if params.keys.contains("url") {
      try await handleSendRichLink(params: params, id: id)
      return
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    let text = stringParam(params["text"]) ?? stringParam(params["message"]) ?? ""
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "message": text,
      "partIndex": intParam(params["part_index"] ?? params["partIndex"]) ?? 0,
      "ddScan": boolParam(params["dd_scan"] ?? params["ddScan"]) ?? true,
    ]
    if let effect = stringParam(params["effect_id"] ?? params["effectId"] ?? params["effect"]),
      !effect.isEmpty
    {
      bridgeParams["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject = stringParam(params["subject"]), !subject.isEmpty {
      bridgeParams["subject"] = subject
    }
    if let reply = stringParam(
      params["reply_to"] ?? params["replyTo"] ?? params["reply_to_guid"] ?? params["message_guid"]
    ), !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }
    if let formatting = params["text_formatting"] ?? params["textFormatting"] {
      bridgeParams["textFormatting"] = formatting
    }

    let sentAt = Date()
    let data = try await invokeBridge(action: .sendMessage, params: bridgeParams)
    var result: [String: Any] = ["ok": true]
    if let queued = data["queued"] as? Bool {
      result["queued"] = queued
    }
    let chatID =
      int64Param(params["chat_id"])
      ?? (try? store.chatInfo(matchingTarget: chatGUID)?.id)
    let options = MessageSendOptions(
      recipient: "",
      text: text,
      service: .auto,
      chatGUID: chatGUID
    )
    if data["queued"] as? Bool == true,
      !text.isEmpty,
      let sentMessage = try? await resolveSentMessage(store, options, chatID, sentAt),
      !sentMessage.guid.isEmpty
    {
      result["guid"] = sentMessage.guid
      result["message_id"] = sentMessage.guid
    } else if data["queued"] as? Bool != true,
      let guid = data["messageGuid"] as? String, !guid.isEmpty
    {
      result["guid"] = guid
      result["message_id"] = guid
    }
    respond(id: id, result: result)
  }

  private func handleSendRichLink(params: [String: Any], id: Any?) async throws {
    let allowedKeys: Set<String> = ["chat_id", "chat_identifier", "chat_guid", "url"]
    if let unsupported = params.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
      throw RPCError.invalidParams("\(unsupported) is not supported with url")
    }
    guard let rawURL = params["url"] as? String else {
      throw RPCError.invalidParams("url must be a string")
    }

    let chatInfo = try await strictRichLinkChatInfo(params)
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
    var result: [String: Any] = ["ok": true]
    if let queued = data["queued"] as? Bool {
      result["queued"] = queued
    }
    let options = MessageSendOptions(
      recipient: "",
      text: prepared.originalURL,
      service: .imessage,
      chatGUID: chatGUID
    )
    if data["queued"] as? Bool == true,
      let sentMessage = try? await resolveSentMessage(store, options, chatInfo.id, sentAt),
      !sentMessage.guid.isEmpty
    {
      result["guid"] = sentMessage.guid
      result["message_id"] = sentMessage.guid
    } else if data["queued"] as? Bool != true,
      let guid = data["messageGuid"] as? String, !guid.isEmpty
    {
      result["guid"] = guid
      result["message_id"] = guid
    }
    respond(id: id, result: result)
  }

  private func strictRichLinkChatInfo(_ params: [String: Any]) async throws -> ChatInfo {
    let targetKeys = ["chat_id", "chat_identifier", "chat_guid"]
    let supplied = targetKeys.filter { params.keys.contains($0) }
    guard supplied.count == 1, let key = supplied.first else {
      throw RPCError.invalidParams(
        "exactly one of chat_id, chat_identifier, or chat_guid is required")
    }

    let info: ChatInfo?
    switch key {
    case "chat_id":
      guard
        let number = params[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        !["f", "d", "D"].contains(String(cString: number.objCType)),
        let chatID = Int64(number.stringValue),
        chatID > 0
      else {
        throw RPCError.invalidParams("chat_id must be a positive integer")
      }
      info = try await cache.info(chatID: chatID)
    case "chat_identifier", "chat_guid":
      guard let target = params[key] as? String, !target.isEmpty else {
        throw RPCError.invalidParams("\(key) must be a non-empty string")
      }
      if key == "chat_identifier" {
        info = try store.chatInfo(
          matchingExactIdentifier: target,
          preferredServices: ["iMessage", "iMessageLite"]
        )
      } else {
        info = try store.chatInfo(matchingExactGUID: target)
      }
    default:
      info = nil
    }

    guard let info, !info.guid.isEmpty else {
      throw RPCError.invalidParams("rich links require an existing chat")
    }
    let service = info.service.lowercased()
    guard service == "imessage" || service == "imessagelite" else {
      throw RPCError.invalidParams("rich links require an iMessage chat")
    }
    return info
  }

  func handleSendAttachment(params: [String: Any], id: Any?) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let file = stringParam(params["file"] ?? params["path"]), !file.isEmpty else {
      throw RPCError.invalidParams("file is required")
    }
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "filePath": try stageAttachment((file as NSString).expandingTildeInPath),
      "isAudioMessage": boolParam(params["audio"] ?? params["is_audio"] ?? params["as_voice"])
        ?? false,
    ]
    if let reply = stringParam(
      params["reply_to"] ?? params["replyTo"] ?? params["reply_to_guid"] ?? params["message_guid"]
    ), !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }
    let data = try await invokeBridge(action: .sendAttachment, params: bridgeParams)
    var result: [String: Any] = ["ok": true]
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
    respond(id: id, result: result)
  }

  func handlePollSend(params: [String: Any], id: Any?) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let question = stringParam(params["question"]), !question.isEmpty else {
      throw RPCError.invalidParams("question is required")
    }
    let options = try rpcPollOptionsParam(params)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "question": question,
      "options": options,
    ]
    if let creatorHandle = stringParam(params["creator_handle"] ?? params["creatorHandle"]),
      !creatorHandle.isEmpty
    {
      bridgeParams["creatorHandle"] = creatorHandle
    }
    if let reply = stringParam(
      params["reply_to"] ?? params["replyTo"] ?? params["reply_to_guid"] ?? params["message_guid"]
    ), !reply.isEmpty {
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
    let comment = stringParam(params["comment"]).flatMap { $0.isEmpty ? nil : $0 } ?? question
    if !comment.isEmpty {
      do {
        _ = try await invokeBridge(
          action: .sendMessage,
          params: [
            "chatGuid": chatGUID,
            "message": comment,
          ])
      } catch {
        let pollGuid = (data["messageGuid"] as? String) ?? ""
        let pollDescription = pollGuid.isEmpty ? "queued poll" : "poll \(pollGuid)"
        FileHandle.standardError.write(
          Data("[imsg] poll.send: comment echo failed for \(pollDescription): \(error)\n".utf8))
      }
    }
    respond(id: id, result: result)
  }

  func handlePollVote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(params: params, id: id, remove: false)
  }

  func handlePollUnvote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(params: params, id: id, remove: true)
  }

  private func handlePollVoteMutation(params: [String: Any], id: Any?, remove: Bool) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard
      let pollGUID = stringParam(
        params["poll_guid"] ?? params["pollGuid"] ?? params["poll_message_guid"]
          ?? params["message_guid"] ?? params["message_id"]), !pollGUID.isEmpty
    else {
      throw RPCError.invalidParams("poll_guid is required")
    }
    guard
      let optionID = stringParam(
        params["option_id"] ?? params["optionId"] ?? params["optionIdentifier"]),
      !optionID.isEmpty
    else {
      throw RPCError.invalidParams("option_id is required")
    }
    // Validate the poll exists and the option belongs to it (mirrors the CLI),
    // so an API caller can't cast a vote against an arbitrary non-poll GUID.
    let pollOptions = try store.pollOptions(guid: pollGUID)
    guard !pollOptions.isEmpty else {
      throw RPCError.invalidParams("poll \(pollGUID) not found or not decodable")
    }
    guard let matchedOption = pollOptions.first(where: { $0.id == optionID }) else {
      throw RPCError.invalidParams("option_id \(optionID) is not an option of poll \(pollGUID)")
    }
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
      let selectedOptionIDs = try store.pollSelectedOptionIDs(guid: pollGUID)
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
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let messageGUID = rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    let rawReaction = stringParam(params["reaction"] ?? params["kind"] ?? params["emoji"]) ?? ""
    let reactionType = try normalizeBridgeReactionType(
      rawReaction,
      remove: boolParam(params["remove"]) ?? false
    )
    _ = try await invokeBridge(
      action: .sendReaction,
      params: [
        "chatGuid": chatGUID,
        "selectedMessageGuid": messageGUID,
        "reactionType": reactionType,
        "partIndex": intParam(params["part_index"] ?? params["partIndex"]) ?? 0,
      ]
    )
    respond(id: id, result: ["ok": true, "reaction": reactionType])
  }

  func handleMessageEdit(params: [String: Any], id: Any?) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let messageGUID = rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    guard
      let text = stringParam(
        params["text"] ?? params["new_text"] ?? params["newText"] ?? params["edited_message"]
      ), !text.isEmpty
    else {
      throw RPCError.invalidParams("text is required")
    }
    _ = try await invokeBridge(
      action: .editMessage,
      params: [
        "chatGuid": chatGUID,
        "messageGuid": messageGUID,
        "editedMessage": text,
        "backwardsCompatibilityMessage": stringParam(
          params["backwards_compatibility_message"] ?? params["backwardsCompatibilityMessage"]
            ?? params["bc_text"] ?? params["bcText"]) ?? text,
        "partIndex": intParam(params["part_index"] ?? params["partIndex"]) ?? 0,
      ]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleMessageUnsend(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(
      action: .unsendMessage,
      params: params,
      id: id,
      includePartIndex: true
    )
  }

  func handleMessageDelete(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(action: .deleteMessage, params: params, id: id)
  }

  func handleMessageNotifyAnyways(params: [String: Any], id: Any?) async throws {
    try await invokeMessageGUIDBridgeAction(action: .notifyAnyways, params: params, id: id)
  }

  func handleNamePhotoStatus(params: [String: Any], id: Any?) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    let data = try await invokeBridge(
      action: .shouldOfferNicknameSharing,
      params: ["chatGuid": chatGUID]
    )
    respond(id: id, result: data.merging(["ok": true]) { current, _ in current })
  }

  func handleNamePhotoShare(params: [String: Any], id: Any?) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    let data = try await invokeBridge(action: .shareNickname, params: ["chatGuid": chatGUID])
    respond(id: id, result: data.merging(["ok": true]) { current, _ in current })
  }

  private func invokeMessageGUIDBridgeAction(
    action: BridgeAction,
    params: [String: Any],
    id: Any?,
    includePartIndex: Bool = false
  ) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let messageGUID = rpcMessageGUIDParam(params) else {
      throw RPCError.invalidParams("message_id or message_guid is required")
    }
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "messageGuid": messageGUID,
    ]
    if includePartIndex {
      bridgeParams["partIndex"] = intParam(params["part_index"] ?? params["partIndex"]) ?? 0
    }
    _ = try await invokeBridge(action: action, params: bridgeParams)
    respond(id: id, result: ["ok": true])
  }
}

func rpcPollOptionsParam(_ params: [String: Any]) throws -> [String] {
  let raw = params["options"] ?? params["option"]
  let values: [Any]
  if let array = raw as? [Any] {
    values = array
  } else if let string = raw as? String {
    values = [string]
  } else {
    throw RPCError.invalidParams("options is required")
  }

  let options = values.compactMap { value -> String? in
    guard let string = stringParam(value) else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if options.count < 2 {
    throw RPCError.invalidParams("at least two poll options are required")
  }
  return options
}

func rpcMessageGUIDParam(_ params: [String: Any]) -> String? {
  let raw = stringParam(
    params["message_id"] ?? params["messageId"] ?? params["message_guid"] ?? params["messageGuid"]
      ?? params["message"]
  )
  let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return trimmed.isEmpty ? nil : trimmed
}

func normalizeBridgeReactionType(_ raw: String, remove: Bool = false) throws -> String {
  var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if value.isEmpty {
    throw RPCError.invalidParams("reaction, kind, or emoji is required")
  }
  var shouldRemove = remove
  if value.hasPrefix("remove-") {
    shouldRemove = true
    value.removeFirst("remove-".count)
  }
  let normalized: String
  switch value {
  case "love", "heart", "❤️", "❤":
    normalized = "love"
  case "like", "thumbsup", "thumbs-up", "+1", "👍":
    normalized = "like"
  case "dislike", "thumbsdown", "thumbs-down", "-1", "👎":
    normalized = "dislike"
  case "laugh", "haha", "lol", "😂", "🤣":
    normalized = "laugh"
  case "emphasize", "emphasis", "!!", "‼", "‼️":
    normalized = "emphasize"
  case "question", "?", "❓":
    normalized = "question"
  default:
    throw RPCError.invalidParams(
      "unsupported tapback reaction \(raw); use love, like, dislike, laugh, emphasize, or question"
    )
  }
  let result = shouldRemove ? "remove-\(normalized)" : normalized
  guard BridgeReactionKind(rawValue: result) != nil else {
    throw RPCError.invalidParams("unsupported tapback reaction \(raw)")
  }
  return result
}
