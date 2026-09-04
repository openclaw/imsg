import Commander
import Foundation
import IMsgCore

enum ReadCommand {
  static let spec = CommandSpec(
    name: "read",
    abstract: "Mark messages as read for a chat",
    discussion: """
      Marks messages as read via IMCore advanced features.
      Requires SIP disabled and Messages launched with `imsg launch`.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "to",
            names: [.long("to"), .aliasLong("handle")],
            help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;-;+14155551212)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
        ]
      )
    ),
    usageExamples: [
      "imsg read --to +14155551212",
      "imsg read --handle steipete@gmail.com",
      "imsg read --chat-id 1",
      "imsg read --chat-identifier \"iMessage;-;+14155551212\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    markAsRead: @escaping (String) async throws -> Void = {
      try await IMCoreBridge.shared.markAsRead(handle: $0)
    }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let input = ChatTargetInput(
      recipient: values.option("to") ?? "",
      chatID: try values.optionChatID(),
      chatIdentifier: values.option("chatIdentifier") ?? "",
      chatGUID: values.option("chatGUID") ?? ""
    )

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
      resolvedIdentifier = input.recipient
    }

    try await markAsRead(resolvedIdentifier)

    if runtime.jsonOutput {
      try JSONLines.print(ReadResult(success: true, handle: resolvedIdentifier, markedAsRead: true))
    } else {
      Swift.print("marked as read: \(resolvedIdentifier)")
    }
  }
}

private struct ReadResult: Codable {
  let success: Bool
  let handle: String
  let markedAsRead: Bool

  enum CodingKeys: String, CodingKey {
    case success
    case handle
    case markedAsRead = "marked_as_read"
  }
}
