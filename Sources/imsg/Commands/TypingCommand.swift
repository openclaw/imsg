import Commander
import Foundation
import IMsgCore

enum TypingCommand {
  static let spec = CommandSpec(
    name: "typing",
    abstract: "Send typing indicator to a chat",
    discussion: """
      Sends typing indicators via IMCore advanced features.
      Requires SIP disabled and Messages launched with `imsg launch`.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;-;+14155551212)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(
            label: "duration", names: [.long("duration")],
            help: "how long to show typing (e.g. 5s, 3000ms); omit for start-only"),
          .make(
            label: "stop", names: [.long("stop")],
            help: "stop typing indicator instead of starting"),
          .make(
            label: "service", names: [.long("service")],
            help: "service to use: imessage|sms|auto"),
        ]
      )
    ),
    usageExamples: [
      "imsg typing --to +14155551212",
      "imsg typing --to +14155551212 --duration 5s",
      "imsg typing --to +14155551212 --stop true",
      "imsg typing --chat-identifier \"iMessage;-;+14155551212\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    startTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.startTyping(chatIdentifier: $0)
    },
    stopTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.stopTyping(chatIdentifier: $0)
    },
    typeForDuration: @escaping (String, TimeInterval) async throws -> Void = {
      try await TypingIndicator.typeForDuration(chatIdentifier: $0, duration: $1)
    }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let input = ChatTargetInput(
      recipient: values.option("to") ?? "",
      chatID: try values.optionChatID(),
      chatIdentifier: values.option("chatIdentifier") ?? "",
      chatGUID: values.option("chatGUID") ?? ""
    )
    let stopFlag = try parseStopFlag(values.option("stop"))
    let durationRaw = values.option("duration") ?? ""
    let serviceRaw = values.option("service") ?? "imessage"

    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: ParsedValuesError.invalidOption("to"),
      missingRecipientError: ParsedValuesError.missingOption("to")
    )

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in
        let store = try storeFactory(dbPath)
        return try store.chatInfo(chatID: chatID)
      },
      unknownChatError: { chatID in
        IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
    )
    let resolvedIdentifier: String
    if let preferred = resolvedTarget.preferredIdentifier {
      resolvedIdentifier = preferred
    } else if input.hasChatTarget {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    } else {
      resolvedIdentifier = try ChatTargetResolver.directTypingIdentifier(
        recipient: input.recipient,
        serviceRaw: serviceRaw,
        invalidServiceError: { IMsgError.invalidService($0) }
      )
    }

    if stopFlag {
      try stopTyping(resolvedIdentifier)
      if runtime.jsonOutput {
        try JSONLines.print(["status": "stopped"])
      } else {
        Swift.print("typing indicator stopped")
      }
      return
    }

    if !durationRaw.isEmpty {
      let seconds = try parseDurationToSeconds(durationRaw)
      try await typeForDuration(resolvedIdentifier, seconds)
      if runtime.jsonOutput {
        try JSONLines.print(["status": "completed", "duration_s": "\(seconds)"])
      } else {
        Swift.print("typing indicator shown for \(durationRaw)")
      }
      return
    }

    try startTyping(resolvedIdentifier)
    if runtime.jsonOutput {
      try JSONLines.print(["status": "started"])
    } else {
      Swift.print("typing indicator started")
    }
  }

  private static func parseStopFlag(_ raw: String?) throws -> Bool {
    guard let raw else { return false }
    if raw == "true" { return true }
    if raw == "false" { return false }
    throw ParsedValuesError.invalidOption("stop")
  }

  private static func parseDurationToSeconds(_ raw: String) throws -> TimeInterval {
    guard let seconds = DurationParser.parse(raw), seconds > 0 else {
      throw IMsgError.typingIndicatorFailed(
        "Invalid duration: \(raw). Use e.g. 5s, 3000ms, 1m, or 1h")
    }
    return seconds
  }
}
