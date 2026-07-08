import Commander
import Foundation
import IMsgCore

enum ScheduledCommand {
  static let spec = CommandSpec(
    name: "scheduled",
    abstract: "List or cancel scheduled messages",
    discussion: "Requires the IMCore bridge for cancel. Listing is read-only from chat.db.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "list|cancel", isOptional: false),
          .make(label: "guid", help: "message guid for cancel", isOptional: true),
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "limit", names: [.long("limit")], help: "max rows for list")
        ]
      )
    ),
    usageExamples: [
      "imsg scheduled list --json",
      "imsg scheduled cancel MESSAGE-GUID",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    }
  ) async throws {
    switch values.argument(0) {
    case "list":
      try runList(values: values, runtime: runtime, storeFactory: storeFactory)
    case "cancel":
      try await runCancel(values: values, runtime: runtime, invokeBridge: invokeBridge)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  private static func runList(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore
  ) throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 50
    let messages = try storeFactory(dbPath).scheduledMessages(limit: limit)
    if runtime.jsonOutput {
      for message in messages {
        try JSONLines.print(ScheduledMessagePayload(message))
      }
      return
    }
    for message in messages {
      StdoutWriter.writeLine(
        "\(CLIISO8601.format(message.scheduledAt)) \(message.guid) [\(message.chatID)] \(message.text)"
      )
    }
  }

  private static func runCancel(
    values: ParsedValues,
    runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async throws {
    guard let guid = values.argument(1)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !guid.isEmpty
    else {
      throw ParsedValuesError.missingOption("guid")
    }
    _ = try await BridgeOutput.invokeAndEmit(
      action: .cancelScheduledMessage,
      params: ["messageGuid": guid],
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { _ in
      "scheduled: canceled (guid=\(guid))"
    }
  }
}

struct ScheduledMessagePayload: Codable {
  let id: Int64
  let guid: String
  let chatID: Int64
  let chatIdentifier: String
  let chatGUID: String
  let chatName: String
  let text: String
  let service: String
  let scheduledAt: String
  let scheduleType: Int
  let scheduleState: Int

  init(_ message: ScheduledMessage) {
    self.id = message.rowID
    self.guid = message.guid
    self.chatID = message.chatID
    self.chatIdentifier = message.chatIdentifier
    self.chatGUID = message.chatGUID
    self.chatName = message.chatName
    self.text = message.text
    self.service = message.service
    self.scheduledAt = CLIISO8601.format(message.scheduledAt)
    self.scheduleType = message.scheduleType
    self.scheduleState = message.scheduleState
  }

  enum CodingKeys: String, CodingKey {
    case id
    case guid
    case chatID = "chat_id"
    case chatIdentifier = "chat_identifier"
    case chatGUID = "chat_guid"
    case chatName = "chat_name"
    case text
    case service
    case scheduledAt = "scheduled_at"
    case scheduleType = "schedule_type"
    case scheduleState = "schedule_state"
  }
}
