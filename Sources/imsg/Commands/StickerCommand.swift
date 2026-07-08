import Commander
import Foundation
import IMsgCore

enum StickerCommand {
  static let spec = CommandSpec(
    name: "sticker",
    abstract: "Send an image as an iMessage sticker via the IMCore bridge",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Sends the file as a
      sticker-attributed IMCore transfer. `--attach-to` associates the sticker
      with an existing message bubble.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "path to sticker image"),
          .make(
            label: "attachTo", names: [.long("attach-to")],
            help: "guid of message bubble to attach the sticker to"),
          .make(label: "part", names: [.long("part")], help: "part index (default 0)"),
        ]
      )
    ),
    usageExamples: [
      "imsg sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png",
      "imsg sticker --chat 'iMessage;-;+15551234567' --file ~/Pictures/sticker.png --attach-to MSG_GUID",
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
    stageAttachment: @escaping (String) throws -> String = MessageSender
      .stageAttachmentForMessagesApp
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let file = values.option("file"), !file.isEmpty else {
      throw ParsedValuesError.missingOption("file")
    }

    let expanded = (file as NSString).expandingTildeInPath
    var params: [String: Any] = [
      "chatGuid": chat,
      "filePath": try stageAttachment(expanded),
      "partIndex": Int(values.option("part") ?? "0") ?? 0,
    ]
    if let attachTo = values.option("attachTo"), !attachTo.isEmpty {
      params["selectedMessageGuid"] = attachTo
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
