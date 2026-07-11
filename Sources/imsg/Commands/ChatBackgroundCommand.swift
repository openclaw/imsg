import Commander
import Foundation
import IMsgCore

enum ChatBackgroundCommand {
  static let spec = CommandSpec(
    name: "chat-background",
    abstract: "Inspect a Messages chat background",
    discussion:
      "Reads background metadata and cache state from the local Messages database. No bridge or SIP change is required.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "status", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "local chat ROWID")
        ]
      )
    ),
    usageExamples: [
      "imsg chat-background status --chat-id 42 --json"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    guard values.argument(0) == "status" else {
      throw ParsedValuesError.invalidOption("action")
    }
    let rawChatID = try values.optionRequired("chatID")
    guard let chatID = Int64(rawChatID), chatID > 0 else {
      throw ParsedValuesError.invalidOption("chat-id")
    }

    let dbPath = values.option("db") ?? MessageStore.defaultPath
    guard let info = try storeFactory(dbPath).chatBackgroundInfo(chatID: chatID) else {
      throw ChatBackgroundError.chatNotFound
    }

    if runtime.jsonOutput {
      try JSONLines.print(ChatBackgroundPayload(info))
      return
    }

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

struct ChatBackgroundPayload: Encodable {
  let ok = true
  let chatID: Int64
  let chatGUID: String
  let backgroundSet: Bool
  let backgroundChannelGUID: String?
  let assetURL: String?
  let assetID: String?
  let objectID: String?
  let fileSize: Int64?
  let posterVersion: Int64?
  let communicationSafetyState: Int64?
  let version: Int64?
  let cachePath: String?
  let cacheExists: Bool?
  let watchBackgroundPath: String?
  let watchBackgroundExists: Bool?
  let latestEvent: ChatBackgroundEventPayload?

  init(_ info: ChatBackgroundInfo) {
    self.chatID = info.chatID
    self.chatGUID = info.chatGUID
    self.backgroundSet = info.backgroundChannelGUID != nil
    self.backgroundChannelGUID = info.backgroundChannelGUID
    self.assetURL = info.assetURL
    self.assetID = info.assetID
    self.objectID = info.objectID
    self.fileSize = info.fileSize
    self.posterVersion = info.posterVersion
    self.communicationSafetyState = info.communicationSafetyState
    self.version = info.version
    self.cachePath = info.cachePath
    self.cacheExists = info.cachePath == nil ? nil : info.cacheExists
    self.watchBackgroundPath = info.watchBackgroundPath
    self.watchBackgroundExists = info.watchBackgroundPath == nil ? nil : info.watchBackgroundExists
    self.latestEvent = info.latestEvent.map(ChatBackgroundEventPayload.init)
  }

  enum CodingKeys: String, CodingKey {
    case ok
    case chatID = "chat_id"
    case chatGUID = "chat_guid"
    case backgroundSet = "background_set"
    case backgroundChannelGUID = "background_channel_guid"
    case assetURL = "asset_url"
    case assetID = "asset_id"
    case objectID = "object_id"
    case fileSize = "file_size"
    case posterVersion = "poster_version"
    case communicationSafetyState = "communication_safety_state"
    case version
    case cachePath = "cache_path"
    case cacheExists = "cache_exists"
    case watchBackgroundPath = "watch_background_path"
    case watchBackgroundExists = "watch_background_exists"
    case latestEvent = "latest_event"
  }
}

struct ChatBackgroundEventPayload: Encodable {
  let rowID: Int64
  let guid: String
  let action: String
  let date: String

  init(_ event: ChatBackgroundEvent) {
    self.rowID = event.rowID
    self.guid = event.guid
    self.action = event.action
    self.date = CLIISO8601.format(event.date)
  }

  enum CodingKeys: String, CodingKey {
    case rowID = "row_id"
    case guid
    case action
    case date
  }
}

enum ChatBackgroundError: LocalizedError, CustomStringConvertible, Equatable {
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
