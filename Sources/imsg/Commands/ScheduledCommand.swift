import Commander
import Foundation
import IMsgCore

enum ScheduledCommand {
  static let spec = CommandSpec(
    name: "scheduled",
    abstract: "List scheduled messages",
    discussion: "Lists future scheduled rows read-only from chat.db.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "list", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "limit", names: [.long("limit")], help: "max rows for list")
        ]
      )
    ),
    usageExamples: [
      "imsg scheduled list --json"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    switch values.argument(0) {
    case "list":
      try runList(values: values, runtime: runtime, storeFactory: storeFactory)
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
    let limit: Int
    if let rawLimit = values.option("limit") {
      guard let parsed = Int(rawLimit), parsed > 0 else {
        throw ParsedValuesError.invalidOption("limit")
      }
      limit = parsed
    } else {
      limit = 50
    }
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
