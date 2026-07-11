import CoreFoundation
import Foundation
import IMsgCore

extension RPCServer {
  func handleSendSticker(params: [String: Any], id: Any?) async throws {
    let supportedParams: Set<String> = [
      "chat_id", "chat_identifier", "chat_guid", "file", "attach_to", "part_index",
    ]
    if let unknown = params.keys.filter({ !supportedParams.contains($0) }).sorted().first {
      throw RPCError.invalidParams("unknown send.sticker param: \(unknown)")
    }
    let chatKeys = ["chat_id", "chat_identifier", "chat_guid"].filter { params[$0] != nil }
    guard chatKeys.count == 1 else {
      throw RPCError.invalidParams(
        "exactly one of chat_id, chat_identifier, or chat_guid is required"
      )
    }
    if let rawChatID = params["chat_id"] {
      guard let chatID = strictStickerInt(rawChatID), chatID > 0 else {
        throw RPCError.invalidParams("chat_id must be a positive integer")
      }
    } else {
      let key = chatKeys[0]
      guard let value = params[key] as? String, !value.isEmpty else {
        throw RPCError.invalidParams("\(key) must be a nonempty string")
      }
    }
    let requestedChatGUID = try await resolveChatGUIDParam(
      params,
      preferredServices: ["iMessage", "iMessageLite"]
    )
    let chatInfo =
      try store.chatInfo(
        matchingTarget: requestedChatGUID,
        preferredServices: ["iMessage", "iMessageLite"]
      )
      ?? store.chatInfo(
        matchingTarget: stickerChatLookupTarget(requestedChatGUID),
        preferredServices: ["iMessage", "iMessageLite"]
      )
    let chatGUID: String
    if params["chat_guid"] != nil,
      let directGUID = directStickerChatGUID(requestedChatGUID)
    {
      chatGUID = directGUID
    } else if let chatInfo,
      !chatInfo.guid.isEmpty,
      isStickerIMessageService(chatInfo.service)
    {
      chatGUID = chatInfo.guid
    } else {
      throw RPCError.invalidParams(StickerSendValidationError.iMessageRequired.description)
    }
    guard let file = params["file"] as? String, !file.isEmpty else {
      throw RPCError.invalidParams("file is required")
    }

    let explicitPart: Int?
    if let rawPart = params["part_index"] {
      guard let parsed = strictStickerInt(rawPart) else {
        throw RPCError.invalidParams("part_index must be an integer")
      }
      explicitPart = parsed
    } else {
      explicitPart = nil
    }
    let rawTarget: String?
    if let value = params["attach_to"] {
      guard let parsed = value as? String else {
        throw RPCError.invalidParams("attach_to must be a string")
      }
      rawTarget = parsed
    } else {
      rawTarget = nil
    }
    let target: StickerSendTarget?
    do {
      target = try StickerSendTarget.resolve(rawTarget: rawTarget, explicitPart: explicitPart)
    } catch let error as StickerSendValidationError {
      throw RPCError.invalidParams(error.description)
    }
    if let target {
      let belongsToChat = try store.messageBelongsToChat(
        messageGUID: target.messageGUID,
        chatGUID: chatGUID
      )
      if !belongsToChat {
        throw RPCError.invalidParams(StickerSendValidationError.targetNotInChat.description)
      }
    }

    let asset: PreparedStickerAsset
    do {
      asset = try stageSticker((file as NSString).expandingTildeInPath)
    } catch let error as StickerAssetError {
      switch error {
      case .couldNotStage, .unsupportedPlatform:
        throw RPCError.internalError(String(describing: error))
      default:
        throw RPCError.invalidParams(String(describing: error))
      }
    }
    defer { StickerAssetPreparer.discard(asset) }
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "filePath": asset.stagedPath,
      "contentHash": asset.sha256,
      "pixelWidth": asset.pixelWidth,
      "pixelHeight": asset.pixelHeight,
      "accessibilityLabel": asset.accessibilityLabel,
      "targetPartIndex": target?.partIndex ?? 0,
    ]
    if let target {
      bridgeParams["selectedMessageGuid"] = target.messageGUID
    }
    let data = try await invokeBridge(action: .sendSticker, params: bridgeParams)
    var result: [String: Any] = ["ok": true]
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
    if let transferGuid = data["transferGuid"] as? String, !transferGuid.isEmpty {
      result["transfer_guid"] = transferGuid
    }
    respond(id: id, result: result)
  }
}

private func strictStickerInt(_ value: Any) -> Int? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  // Keep JSON integers distinct from integral floats/exponents on Darwin and Linux.
  let type = String(cString: number.objCType)
  guard type != "f", type != "d", type != "D" else { return nil }
  return Int(number.stringValue)
}
