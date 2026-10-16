import Commander
import Foundation
import IMsgCore

enum BridgeReactCommand {
  static let spec = CommandSpec(
    name: "tapback",
    abstract: "Send a tapback reaction via the IMCore bridge",
    discussion: """
      `imsg tapback` uses the bridge for reliability across macOS versions.
      `imsg react` (AppleScript) remains for SIP-on machines.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(
            label: "kind", names: [.long("kind")],
            help: "love|like|dislike|laugh|emphasize|question, or an emoji"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ],
        flags: [
          .make(
            label: "remove", names: [.long("remove")],
            help: "remove this reaction instead of adding")
        ]
      )
    ),
    usageExamples: [
      "imsg tapback --chat 'iMessage;-;+15551234567' --message ABCD-EFGH --kind love"
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
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    guard let kind = values.option("kind"), !kind.isEmpty else {
      throw ParsedValuesError.missingOption("kind")
    }
    let remove = values.flag("remove")
    var params: [String: Any] = [
      "chatGuid": chat,
      "selectedMessageGuid": message,
      "partIndex": try values.optionInt("part", minimum: 0) ?? 0,
    ]
    let summary: String
    if let emoji = customTapbackEmoji(kind) {
      guard bridgeSupportsEmojiTapbacks(try await invokeBridge(.status, [:])) else {
        throw IMsgError.unsupportedReaction(
          "running bridge does not support emoji tapbacks; restart Messages with the current imsg bridge"
        )
      }
      params["emoji"] = emoji
      params["remove"] = remove
      summary = remove ? "tapback: \(emoji) removed" : "tapback: \(emoji) sent"
    } else {
      let reactionType: String
      do {
        reactionType = try normalizeBridgeReactionType(kind, remove: remove)
      } catch {
        throw IMsgError.unsupportedReaction(
          "\(kind); use love, like, dislike, laugh, emphasize, question, or a single emoji")
      }
      params["reactionType"] = reactionType
      summary = "tapback: \(reactionType) sent"
    }
    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendReaction, params: params, runtime: runtime, invokeBridge: invokeBridge
    ) { _ in summary }
  }
}

// MARK: - edit

enum EditCommand {
  static let spec = CommandSpec(
    name: "edit",
    abstract: "Edit a sent message",
    discussion: "Requires macOS 13+ (selector-probed at startup).",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(label: "newText", names: [.long("new-text")], help: "replacement text"),
          .make(
            label: "bcText",
            names: [.long("bc-text")],
            help: "backwards-compat text shown to older clients (default: same as new-text)"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ]
      )
    ),
    usageExamples: ["imsg edit --chat ... --message <guid> --new-text 'updated'"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    guard let newText = values.option("newText"), !newText.isEmpty else {
      throw ParsedValuesError.missingOption("new-text")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
      "editedMessage": newText,
      "backwardsCompatibilityMessage": values.option("bcText") ?? newText,
      "partIndex": try values.optionInt("part", minimum: 0) ?? 0,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .editMessage, params: params, runtime: runtime
    ) { _ in "edit: queued" }
  }
}

// MARK: - unsend

enum UnsendCommand {
  static let spec = CommandSpec(
    name: "unsend",
    abstract: "Retract a sent message",
    discussion: "Requires macOS 13+ (selector-probed at startup).",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ]
      )
    ),
    usageExamples: ["imsg unsend --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
      "partIndex": try values.optionInt("part", minimum: 0) ?? 0,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .unsendMessage, params: params, runtime: runtime
    ) { _ in "unsend: queued" }
  }
}

// MARK: - delete-message

enum DeleteMessageCommand {
  static let spec = CommandSpec(
    name: "delete-message",
    abstract: "Delete a single message from a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
        ]
      )
    ),
    usageExamples: ["imsg delete-message --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .deleteMessage, params: params, runtime: runtime
    ) { _ in "delete-message: queued" }
  }
}

// MARK: - notify-anyways

enum NotifyAnywaysCommand {
  static let spec = CommandSpec(
    name: "notify-anyways",
    abstract: "Force a notification for a message that was filtered/suppressed",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
        ]
      )
    ),
    usageExamples: ["imsg notify-anyways --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = ["chatGuid": chat, "messageGuid": message]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .notifyAnyways, params: params, runtime: runtime
    ) { _ in "notify-anyways: queued" }
  }
}
