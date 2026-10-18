import Foundation
import IMsgCore

private func bridgeDeliveryVerificationFailure(
  action: BridgeAction,
  detail: String
) -> DeliveryFailure {
  DeliveryFailure(
    disposition: .mayHaveCompleted,
    transport: .bridgeV2,
    operation: action.rawValue,
    detail: detail
  )
}

func rpcPollOptionsParam(_ params: RPCParameters) throws -> [String] {
  guard let values = try params.stringArray("options", aliases: ["option"]) else {
    throw RPCError.invalidParams("options is required")
  }

  let options = values.compactMap { value -> String? in
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if options.count < 2 {
    throw RPCError.invalidParams("at least two poll options are required")
  }
  return options
}

func rpcMessageGUIDParam(_ params: RPCParameters) throws -> String? {
  let raw = try params.string(
    "message_id", aliases: ["messageId", "message_guid", "messageGuid", "message"])
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

extension RPCServer {
  func bridgeSendVerificationBaseline() async throws -> (
    database: RPCDatabaseResources, rowID: Int64
  ) {
    let database = try await databaseResources.require()
    return (database, try database.store.maxRowID())
  }

  func verifiedBridgeSendResponse(
    _ data: [String: Any],
    params: RPCParameters,
    chatGUID: String,
    action: BridgeAction,
    database: RPCDatabaseResources,
    baselineRowID: Int64
  ) async throws -> [String: Any] {
    guard let bridgeGUID = data["messageGuid"] as? String, !bridgeGUID.isEmpty else {
      throw bridgeDeliveryVerificationFailure(
        action: action,
        detail: "The bridge completed, but returned no message GUID to verify."
      )
    }

    let sentMessage: Message?
    do {
      guard
        let chatInfo = try bridgeResponseChatInfo(
          params: params,
          chatGUID: chatGUID,
          database: database
        )
      else {
        throw bridgeDeliveryVerificationFailure(
          action: action, detail: "The target chat could not be resolved after bridge publication."
        )
      }
      sentMessage = try await SentMessageVerifier.resolveSentMessage(
        store: database.store,
        messageGUID: bridgeGUID,
        chatInfo: chatInfo,
        afterRowID: baselineRowID
      )
    } catch let failure as DeliveryFailure {
      throw failure
    } catch {
      throw bridgeDeliveryVerificationFailure(
        action: action,
        detail: "The Messages database could not verify the published bridge operation."
      )
    }

    guard let sentMessage, !sentMessage.guid.isEmpty else {
      throw bridgeDeliveryVerificationFailure(
        action: action,
        detail: "The bridge completed, but its message GUID was not a new row in the target chat."
      )
    }

    var enriched = data
    let responseChatGUID =
      ((data["chatGuid"] as? String).flatMap { $0.isEmpty ? nil : $0 })
      ?? chatGUID
    if !responseChatGUID.isEmpty {
      enriched["chat_guid"] = responseChatGUID
    }
    enriched["id"] = sentMessage.rowID
    enriched["guid"] = sentMessage.guid
    enriched["message_id"] = sentMessage.guid
    enriched["messageGuid"] = sentMessage.guid
    return enriched
  }

  func requireRichAttachmentCapability(requiresMetadata: Bool) async throws {
    let status: [String: Any]
    do {
      status = try await invokeBridge(action: .status, params: [:])
    } catch {
      throw DeliveryFailure(
        disposition: .notStarted,
        transport: .bridgeV2,
        operation: BridgeAction.sendAttachment.rawValue,
        detail: "Bridge capability inspection failed before the send was published."
      )
    }
    let selectors = status["selectors"] as? [String: Any]
    guard selectors?["sendAttachment"] as? Bool == true else {
      throw RPCError.internalError(
        "running bridge does not support attachments; restart Messages with the current imsg bridge"
      )
    }
    if requiresMetadata, status["attachment_metadata"] as? Bool != true {
      throw RPCError.internalError(
        "running bridge does not support rich attachment metadata; "
          + "restart Messages with the current imsg bridge"
      )
    }
  }

  func bridgeResponseChatInfo(
    params: RPCParameters,
    chatGUID: String,
    database: RPCDatabaseResources?
  ) throws -> ChatInfo? {
    guard let database else { return nil }
    if let chatID = try params.int64("chat_id") {
      return try database.store.chatInfo(chatID: chatID)
    }
    return try database.store.chatInfo(matchingTarget: chatGUID)
  }

  func strictRichLinkChatInfo(
    _ params: RPCParameters,
    database: RPCDatabaseResources
  ) async throws -> ChatInfo {
    let target = try params.chatTarget()

    let info: ChatInfo?
    if let chatID = target.chatID {
      info = try database.store.chatInfo(chatID: chatID)
    } else if !target.chatIdentifier.isEmpty {
      info = try database.store.chatInfo(
        matchingExactIdentifier: target.chatIdentifier,
        preferredServices: ["iMessage", "iMessageLite"]
      )
    } else {
      info = try database.store.chatInfo(matchingExactGUID: target.chatGUID)
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
}
