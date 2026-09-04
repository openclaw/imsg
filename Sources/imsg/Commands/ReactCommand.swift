import Commander
import Foundation
import IMsgCore

enum ReactCommand {
  static let spec = CommandSpec(
    name: "react",
    abstract: "Send a tapback reaction to the most recent message",
    discussion: """
      Sends a tapback reaction to the most recent incoming message in the specified chat.

      IMPORTANT LIMITATIONS:
      - Only reacts to the MOST RECENT incoming message in the conversation
      - Requires Messages.app to be running
      - Uses UI automation (System Events) which requires accessibility permissions

      Reaction types:
        love (❤️), like (👍), dislike (👎), laugh (😂), emphasis (‼️), question (❓)

      Custom emoji tapbacks can be read from history/watch output, but cannot be
      sent reliably through Messages.app AppleScript automation.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid to react in"),
          .make(
            label: "reaction", names: [.long("reaction"), .short("r")],
            help: "reaction type: love, like, dislike, laugh, emphasis, question"),
        ],
        flags: []
      )
    ),
    usageExamples: [
      "imsg react --chat-id 1 --reaction like",
      "imsg react --chat-id 1 -r love",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    appleScriptRunner: @escaping (String, [String]) throws -> Void = { source, arguments in
      try runAppleScript(source, arguments: arguments)
    }
  ) async throws {
    guard let chatID = try values.optionChatID() else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    guard let reactionString = values.option("reaction") else {
      throw ParsedValuesError.missingOption("reaction")
    }
    guard let reactionType = ReactionType.parse(reactionString) else {
      throw IMsgError.invalidReaction(reactionString)
    }
    if case .custom(let emoji) = reactionType, !isSingleEmoji(emoji) {
      throw IMsgError.invalidReaction(reactionString)
    }
    if case .custom(let emoji) = reactionType {
      throw IMsgError.unsupportedReaction(
        "custom emoji tapback '\(emoji)' cannot be sent by Messages.app "
          + "AppleScript automation; use love, like, dislike, laugh, emphasis, or question."
      )
    }

    // Get chat info for the GUID
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    guard let chatInfo = try store.chatInfo(chatID: chatID) else {
      throw IMsgError.chatNotFound(chatID: chatID)
    }

    let chatLookup = preferredChatLookup(chatInfo: chatInfo)

    // Send the reaction via AppleScript + System Events
    try sendReaction(
      reactionType: reactionType,
      chatGUID: chatInfo.guid,
      chatLookup: chatLookup,
      appleScriptRunner: appleScriptRunner
    )

    if runtime.jsonOutput {
      let result = ReactResult(
        success: true,
        chatID: chatID,
        reactionType: reactionType.name,
        reactionEmoji: reactionType.emoji
      )
      try JSONLines.print(result)
    } else {
      print("Sent \(reactionType.emoji) reaction to chat \(chatID)")
    }
  }

  private static func sendReaction(
    reactionType: ReactionType,
    chatGUID: String,
    chatLookup: String,
    appleScriptRunner: @escaping (String, [String]) throws -> Void
  ) throws {
    let keyNumber: Int
    switch reactionType {
    case .love: keyNumber = 1
    case .like: keyNumber = 2
    case .dislike: keyNumber = 3
    case .laugh: keyNumber = 4
    case .emphasis: keyNumber = 5
    case .question: keyNumber = 6
    case .custom(let emoji):
      throw IMsgError.unsupportedReaction(
        "custom emoji tapback '\(emoji)' cannot be sent by Messages.app "
          + "AppleScript automation; use love, like, dislike, laugh, emphasis, or question."
      )
    }

    let script = """
      on run argv
        set chatGUID to item 1 of argv
        set chatLookup to item 2 of argv
        set reactionKey to item 3 of argv

        tell application "Messages"
          activate
          set targetChat to chat id chatGUID
        end tell

        delay 0.3

        tell application "System Events"
          tell process "Messages"
            keystroke "f" using command down
            delay 0.15
            keystroke "a" using command down
            keystroke chatLookup
            delay 0.25
            key code 36
            delay 0.35
            keystroke "t" using command down
            delay 0.2
            keystroke reactionKey
            delay 0.1
            key code 36
          end tell
        end tell
      end run
      """
    try appleScriptRunner(script, [chatGUID, chatLookup, "\(keyNumber)"])
  }

  private static func preferredChatLookup(chatInfo: ChatInfo) -> String {
    let preferred = chatInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preferred.isEmpty {
      return preferred
    }
    let identifier = chatInfo.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !identifier.isEmpty {
      return identifier
    }
    return chatInfo.guid
  }

  private static func isSingleEmoji(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1 else { return false }
    guard let scalar = trimmed.unicodeScalars.first else { return false }
    return scalar.properties.isEmoji || scalar.properties.isEmojiPresentation
  }

  /// Bound for react UI automation. Align with the send-style deadline (150s)
  /// used on main for reaction waits; hung osascript still cannot block forever.
  static let osascriptTimeout: TimeInterval = IMsgBridgeProtocol.defaultSendResponseTimeout

  private static func runAppleScript(_ source: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"] + arguments

    let stdinPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardError = stderrPipe

    try process.run()
    if let data = source.data(using: .utf8) {
      stdinPipe.fileHandleForWriting.write(data)
    }
    stdinPipe.fileHandleForWriting.closeFile()
    if ProcessTimeout.waitUntilExit(process, timeout: osascriptTimeout) {
      throw IMsgError.appleScriptFailure(
        "osascript timed out after \(Int(osascriptTimeout))s")
    }

    if process.terminationStatus != 0 {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "Unknown AppleScript error"
      throw IMsgError.appleScriptFailure(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

struct ReactResult: Codable {
  let success: Bool
  let chatID: Int64
  let reactionType: String
  let reactionEmoji: String

  enum CodingKeys: String, CodingKey {
    case success
    case chatID = "chat_id"
    case reactionType = "reaction_type"
    case reactionEmoji = "reaction_emoji"
  }
}
