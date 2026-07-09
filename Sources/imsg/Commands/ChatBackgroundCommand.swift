import Commander
import Foundation
import IMsgCore

enum ChatBackgroundCommand {
  static let spec = CommandSpec(
    name: "chat-background",
    abstract: "Inspect, set, or clear a macOS 26 Messages chat background",
    discussion: """
      Requires `imsg launch` on macOS 26+. This is a guarded private-API probe:
      the helper reports an error unless the running Messages classes expose a
      known chat-background selector. Setting a background expects the same
      PosterKit package shape Messages.app uses internally: `--file` points to
      the transcript background package and a sibling path ending in
      `-watchBackground` must exist.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "status|clear|set", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "chatID", names: [.long("chat-id")], help: "local chat ROWID"),
          .make(
            label: "file",
            names: [.long("file")],
            help: "set: path to PosterKit background package"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg chat-background status --chat 'iMessage;+;chat0000' --json",
      "imsg chat-background set --chat 'iMessage;+;chat0000' --file /tmp/bg-package",
      "imsg chat-background clear --chat 'iMessage;+;chat0000'",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore = { try MessageStore(path: $0) },
    stageBackgroundPackage: @escaping (String) throws -> String = MessageSender
      .stageChatBackgroundPackageForMessagesApp,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    }
  ) async throws {
    switch values.argument(0) {
    case "status":
      try emitStatus(values: values, runtime: runtime, storeFactory: storeFactory)
      return
    case "set":
      guard let chat = values.option("chat"), !chat.isEmpty else {
        throw ParsedValuesError.missingOption("chat")
      }
      guard let file = values.option("file"), !file.isEmpty else {
        throw ParsedValuesError.missingOption("file")
      }
      let expanded = (file as NSString).expandingTildeInPath
      _ = try await BridgeOutput.invokeAndEmit(
        action: .setChatBackground,
        params: [
          "chatGuid": chat,
          "filePath": try stageBackgroundPackage(expanded),
        ],
        runtime: runtime,
        invokeBridge: invokeBridge
      ) { data in
        let backgroundGuid = (data["backgroundGuid"] as? String) ?? ""
        return backgroundGuid.isEmpty
          ? "chat-background: set"
          : "chat-background: set (background_guid=\(backgroundGuid))"
      }
      return
    case "clear":
      guard let chat = values.option("chat"), !chat.isEmpty else {
        throw ParsedValuesError.missingOption("chat")
      }
      _ = try await BridgeOutput.invokeAndEmit(
        action: .clearChatBackground,
        params: ["chatGuid": chat],
        runtime: runtime,
        invokeBridge: invokeBridge
      ) { _ in
        "chat-background: cleared"
      }
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  private static func emitStatus(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore
  ) throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    let info: ChatBackgroundInfo?
    if let chatIDString = values.option("chatID"), let chatID = Int64(chatIDString) {
      info = try store.chatBackgroundInfo(chatID: chatID)
    } else if let chat = values.option("chat"), !chat.isEmpty {
      info = try store.chatBackgroundInfo(matchingTarget: chat)
    } else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let info else {
      throw ChatBackgroundError.chatNotFound
    }
    let payload = statusPayload(info)
    if runtime.jsonOutput {
      try JSONLines.printObject(payload)
    } else {
      let state = info.backgroundChannelGUID == nil ? "none" : "set"
      StdoutWriter.writeLine("chat-background: \(state)")
      StdoutWriter.writeLine("chat_id: \(info.chatID)")
      StdoutWriter.writeLine("chat_guid: \(info.chatGUID)")
      if let channelGUID = info.backgroundChannelGUID {
        StdoutWriter.writeLine("background_channel_guid: \(channelGUID)")
        StdoutWriter.writeLine("cache_exists: \(info.cacheExists)")
        StdoutWriter.writeLine("watch_background_exists: \(info.watchBackgroundExists)")
      }
      if let latest = info.latestEvent {
        StdoutWriter.writeLine("latest_event: \(latest.action) row=\(latest.rowID)")
      }
    }
  }

  private static func statusPayload(_ info: ChatBackgroundInfo) -> [String: Any] {
    var payload: [String: Any] = [
      "ok": true,
      "chat_id": info.chatID,
      "chat_guid": info.chatGUID,
      "background_set": info.backgroundChannelGUID != nil,
      "cache_exists": info.cacheExists,
      "watch_background_exists": info.watchBackgroundExists,
    ]
    payload["background_channel_guid"] = info.backgroundChannelGUID ?? NSNull()
    payload["asset_url"] = info.assetURL ?? NSNull()
    payload["asset_id"] = info.assetID ?? NSNull()
    payload["object_id"] = info.objectID ?? NSNull()
    payload["file_size"] = info.fileSize ?? NSNull()
    payload["poster_version"] = info.posterVersion ?? NSNull()
    payload["communication_safety_state"] = info.communicationSafetyState ?? NSNull()
    payload["version"] = info.version ?? NSNull()
    payload["cache_path"] = info.cachePath ?? NSNull()
    payload["watch_background_path"] = info.watchBackgroundPath ?? NSNull()
    if let event = info.latestEvent {
      payload["latest_event"] = [
        "row_id": event.rowID,
        "guid": event.guid,
        "action": event.action,
        "date": ISO8601DateFormatter().string(from: event.date),
      ]
    } else {
      payload["latest_event"] = NSNull()
    }
    return payload
  }
}

enum ChatBackgroundError: LocalizedError, CustomStringConvertible {
  case chatNotFound

  var errorDescription: String? {
    switch self {
    case .chatNotFound:
      return "chat not found"
    }
  }

  var description: String {
    errorDescription ?? "chat-background error"
  }
}
