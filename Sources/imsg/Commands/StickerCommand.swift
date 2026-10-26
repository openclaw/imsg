import Commander
import Foundation
import IMsgCore

enum StickerCommand {
  static let spec = CommandSpec(
    name: "send-sticker",
    abstract: "Send an image as an iMessage sticker via the IMCore bridge",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Sends the file as a
      sticker-attributed IMCore transfer. `--attach-to` associates the sticker
      with an existing message bubble; `--x`, `--y`, `--scale`, and `--rotation`
      place it there. Accepts PNG/APNG, GIF, or JPEG images up to 500 KiB,
      618x618 pixels, 100 frames, and 25 million total decoded pixels. Stickers
      are iMessage-only.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "path to sticker image"),
          .make(
            label: "attachTo", names: [.long("attach-to")],
            help: "guid of message bubble to attach the sticker to"),
          .make(
            label: "targetPart", names: [.long("target-part")],
            help: "target bubble part index (default 0)"),
          .make(
            label: "x", names: [.long("x")],
            help: "sticker center across the bubble: 0 left, 1 right (default 0.5)"),
          .make(
            label: "y", names: [.long("y")],
            help: "sticker center down the bubble: 0 top, 1 bottom (default 0.5)"),
          .make(
            label: "scale", names: [.long("scale")],
            help: "sticker size multiplier, 0.1 to 4 (default 1)"),
          .make(
            label: "rotation", names: [.long("rotation")],
            help: "clockwise rotation in degrees, -180 to 180 (default 0)"),
        ]
      )
    ),
    usageExamples: [
      "imsg send-sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png",
      "imsg send-sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png --attach-to MSG_GUID --target-part 0",
      "imsg send-sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png --attach-to MSG_GUID --x 0.9 --y 0.1 --scale 0.5 --rotation 15",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    },
    resolveChat: @escaping (String, String) throws -> (guid: String, service: String)? = {
      target, dbPath in
      let store = try MessageStore(path: dbPath)
      let info =
        try store.chatInfo(
          matchingTarget: target,
          preferredServices: ["iMessage", "iMessageLite"]
        )
        ?? store.chatInfo(
          matchingTarget: stickerChatLookupTarget(target),
          preferredServices: ["iMessage", "iMessageLite"]
        )
      guard let info else { return nil }
      return (info.guid, info.service)
    },
    messageBelongsToChat: @escaping (String, String, String) throws -> Bool = {
      messageGUID, chatGUID, dbPath in
      try MessageStore(path: dbPath).messageBelongsToChat(
        messageGUID: messageGUID,
        chatGUID: chatGUID
      )
    },
    prepareSticker: @escaping (String) throws -> PreparedStickerAsset = {
      try StickerAssetPreparer.prepare(at: $0)
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let file = values.option("file"), !file.isEmpty else {
      throw ParsedValuesError.missingOption("file")
    }
    let explicitPart = try values.optionInt("targetPart", name: "target-part", minimum: 0)
    let target = try StickerSendTarget.resolve(
      rawTarget: values.option("attachTo"),
      explicitPart: explicitPart
    )
    let placement = try StickerPlacement.resolve(
      x: values.optionDouble("x"),
      y: values.optionDouble("y"),
      scale: values.optionDouble("scale"),
      rotation: values.optionDouble("rotation"),
      hasTarget: target != nil
    )
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatGUID: String
    if let directGUID = directStickerChatGUID(chat) {
      chatGUID = directGUID
    } else if let resolvedChat = try resolveChat(chat, dbPath), !resolvedChat.guid.isEmpty {
      guard isStickerIMessageService(resolvedChat.service) else {
        throw StickerSendValidationError.iMessageRequired
      }
      chatGUID = resolvedChat.guid
    } else {
      throw StickerSendValidationError.iMessageRequired
    }

    if let target {
      guard try messageBelongsToChat(target.messageGUID, chatGUID, dbPath) else {
        throw StickerSendValidationError.targetNotInChat
      }
    }
    if placement != nil, !bridgeSupportsStickerPlacement(try await invokeBridge(.status, [:])) {
      throw StickerSendValidationError.placementUnsupported
    }

    let expanded = (file as NSString).expandingTildeInPath
    let asset = try prepareSticker(expanded)
    defer { StickerAssetPreparer.discard(asset) }
    var params: [String: Any] = [
      "chatGuid": chatGUID,
      "filePath": asset.stagedPath,
      "contentHash": asset.sha256,
      "pixelWidth": asset.pixelWidth,
      "pixelHeight": asset.pixelHeight,
      "accessibilityLabel": asset.accessibilityLabel,
      "targetPartIndex": target?.partIndex ?? 0,
    ]
    if let target {
      params["selectedMessageGuid"] = target.messageGUID
    }
    if let placement {
      params["placement"] = placement.bridgeParams
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendSticker,
      params: params,
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      return guid.isEmpty ? "sticker: queued" : "sticker: sent (guid=\(guid))"
    }
  }
}
