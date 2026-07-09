import Commander
import Foundation
import IMsgCore

enum ChatBackgroundCommand {
  static let spec = CommandSpec(
    name: "chat-background",
    abstract: "Set or clear a macOS 26 Messages chat background",
    discussion: """
      Requires `imsg launch` on macOS 26+. This is a guarded private-API probe:
      the helper reports an error unless the running Messages classes expose a
      known chat-background selector.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "set|clear", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "set: path to image"),
        ]
      )
    ),
    usageExamples: [
      "imsg chat-background set --chat 'iMessage;+;chat0000' --file ~/Pictures/bg.jpg",
      "imsg chat-background clear --chat 'iMessage;+;chat0000'",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    stageAttachment: @escaping (String) throws -> String = MessageSender
      .stageAttachmentForMessagesApp,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    var params: [String: Any] = ["chatGuid": chat]
    let action: BridgeAction
    switch values.argument(0) {
    case "set":
      guard let file = values.option("file"), !file.isEmpty else {
        throw ParsedValuesError.missingOption("file")
      }
      let expanded = (file as NSString).expandingTildeInPath
      params["filePath"] = try stageAttachment(expanded)
      action = .setChatBackground
    case "clear":
      action = .clearChatBackground
    default:
      throw ParsedValuesError.invalidOption("action")
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: action,
      params: params,
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { _ in
      values.argument(0) == "set" ? "chat-background: set" : "chat-background: cleared"
    }
  }
}
