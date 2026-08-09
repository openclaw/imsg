import Commander
import Foundation
import IMsgCore

enum SendAttachmentCommand {
  static let spec = CommandSpec(
    name: "send-attachment",
    abstract: "Send a file attachment via the IMCore bridge",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "absolute path to file"),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(
            label: "transport", names: [.long("transport")],
            help: "transport to use: auto|dylib|applescript"),
        ],
        flags: [
          .make(label: "audio", names: [.long("audio")], help: "send as audio message")
        ]
      )
    ),
    usageExamples: [
      "imsg send-attachment --chat 'iMessage;-;+15551234567' --file ~/Pictures/me.jpg"
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
    stageAttachment: @escaping (String) throws -> String =
      MessageSender.stageAttachmentForMessagesApp,
    sendMessage: @escaping (MessageSendOptions) throws -> Void = {
      try MessageSender().send($0)
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let file = values.option("file"), !file.isEmpty else {
      throw ParsedValuesError.missingOption("file")
    }
    let expanded = (file as NSString).expandingTildeInPath
    let transport = values.option("transport") ?? "auto"
    guard ["auto", "dylib", "applescript"].contains(transport) else {
      throw ParsedValuesError.invalidOption("transport")
    }
    let audio = values.flag("audio")
    if transport == "applescript" && audio {
      throw ParsedValuesError.invalidOption("audio")
    }
    let replyTo = values.option("replyTo") ?? ""
    if transport == "applescript" && !replyTo.isEmpty {
      throw ParsedValuesError.invalidOption("reply-to")
    }

    if transport != "applescript" {
      let staged = try stageAttachment(expanded)
      var params: [String: Any] = [
        "chatGuid": chat,
        "filePath": staged,
        "isAudioMessage": audio,
      ]
      if !replyTo.isEmpty {
        params["selectedMessageGuid"] = replyTo
      }
      do {
        let data = try await invokeBridge(.sendAttachment, params)
        let guid = (data["messageGuid"] as? String) ?? ""
        BridgeOutput.emit(data, runtime: runtime, summary: "send-attachment: queued (guid=\(guid))")
        return
      } catch let failure as DeliveryFailure {
        if transport == "dylib" || audio || !replyTo.isEmpty || !failure.retrySafe {
          BridgeOutput.emitError(String(describing: failure), runtime: runtime)
          throw BridgeOutput.EmittedError()
        }
      } catch let error as IMsgBridgeError {
        let bridgeWasNotReady: Bool
        if case .bridgeNotReady = error {
          bridgeWasNotReady = true
        } else {
          bridgeWasNotReady = false
        }
        if transport == "dylib" || audio || !replyTo.isEmpty || !bridgeWasNotReady {
          BridgeOutput.emitError(String(describing: error), runtime: runtime)
          throw BridgeOutput.EmittedError()
        }
      } catch {
        BridgeOutput.emitError(String(describing: error), runtime: runtime)
        throw BridgeOutput.EmittedError()
      }
    }

    try sendMessage(
      MessageSendOptions(
        recipient: "",
        text: "",
        attachmentPath: expanded,
        chatGUID: chat
      ))
    BridgeOutput.emit(
      ["success": true, "transport": "applescript"],
      runtime: runtime,
      summary: "send-attachment: sent via AppleScript"
    )
  }
}
