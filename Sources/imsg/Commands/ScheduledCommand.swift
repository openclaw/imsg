import Commander
import Foundation
import IMsgCore
import IMsgRPC

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
    let limit = try values.optionInt("limit", minimum: 1) ?? 50
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
