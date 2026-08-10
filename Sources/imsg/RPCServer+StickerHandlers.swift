import Foundation
import IMsgCore

extension RPCServer {
  func handleSendSticker(params: [String: Any], id: Any?) async throws {
    let params = try RPCParameters(
      params,
      method: "send.sticker",
      supportedKeys: RPCParameterKeys.combining(
        RPCParameterKeys.chatTarget, ["file", "attach_to", "part_index"])
    )
    let targetInput = try params.chatTarget()
    guard let file = try params.string("file"), !file.isEmpty else {
      throw RPCError.invalidParams("file is required")
    }
    let explicitPart = try params.integer("part_index")
    let rawTarget = try params.string("attach_to")
    let target: StickerSendTarget?
    do {
      target = try StickerSendTarget.resolve(rawTarget: rawTarget, explicitPart: explicitPart)
    } catch let error as StickerSendValidationError {
      throw RPCError.invalidParams(error.description)
    }
    let store = try await databaseResources.require().store
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
    if !targetInput.chatGUID.isEmpty,
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
