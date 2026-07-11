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
      with an existing message bubble. Accepts PNG/APNG, GIF, or JPEG images up
      to 500 KiB, 618x618 pixels, 100 frames, and 25 million total decoded
      pixels. Stickers are iMessage-only.
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
        ]
      )
    ),
    usageExamples: [
      "imsg send-sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png",
      "imsg send-sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png --attach-to MSG_GUID --target-part 0",
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

    let explicitPart: Int?
    if let rawPart = values.option("targetPart") {
      guard let parsed = Int(rawPart) else {
        throw ParsedValuesError.invalidOption("target-part")
      }
      explicitPart = parsed
    } else {
      explicitPart = nil
    }
    let target = try StickerSendTarget.resolve(
      rawTarget: values.option("attachTo"),
      explicitPart: explicitPart
    )
    if let target {
      guard try messageBelongsToChat(target.messageGUID, chatGUID, dbPath) else {
        throw StickerSendValidationError.targetNotInChat
      }
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
