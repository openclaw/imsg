import Commander
import Foundation
import IMsgCore

enum PollCommand {
  static let spec = CommandSpec(
    name: "poll",
    abstract: "Send a native Apple Messages poll",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Use the `send`
      action to create a native Messages Polls extension balloon, or the `vote`
      action to cast a vote on an existing poll.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "send|vote", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid or rowid"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(label: "question", names: [.long("question")], help: "poll question"),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(
            label: "option", names: [.long("option")],
            help: "poll option text; pass at least twice"),
          .make(
            label: "poll", names: [.long("poll")],
            help: "vote: guid of the poll message to vote on"),
          .make(
            label: "optionID", names: [.long("option-id")],
            help: "vote: UUID of the option to select"),
          .make(
            label: "optionIndex", names: [.long("option-index")],
            help: "vote: 1-based option number to select"),
        ]
      )
    ),
    usageExamples: [
      "imsg poll send --chat 'iMessage;-;+15551234567' --question 'Dinner?' --option 'Pizza' --option 'Sushi'",
      "imsg poll send --chat 'iMessage;-;+15551234567' --reply-to ABCD --question 'Approve?' --option 'Yes' --option 'No'",
      "imsg poll vote --chat 'iMessage;-;+15551234567' --poll ABCD --option-id 1B2C-...",
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
    case "send":
      try await runSend(
        values: values, runtime: runtime, storeFactory: storeFactory, invokeBridge: invokeBridge)
    case "vote":
      try await runVote(
        values: values, runtime: runtime, storeFactory: storeFactory, invokeBridge: invokeBridge)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  private static func runSend(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async throws {
    let chat = try resolveChatGUID(values: values, storeFactory: storeFactory)
    guard let question = values.option("question"), !question.isEmpty else {
      throw ParsedValuesError.missingOption("question")
    }
    let options = values.optionValues("option")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard options.count >= 2 else {
      throw ParsedValuesError.missingOption("option")
    }

    var params: [String: Any] = [
      "chatGuid": chat,
      "question": question,
      "options": options,
    ]
    if let reply = values.option("replyTo"), !reply.isEmpty {
      params["selectedMessageGuid"] = reply
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendPoll,
      params: params,
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      return guid.isEmpty ? "poll: queued" : "poll: sent (guid=\(guid))"
    }
  }

  private static func runVote(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async throws {
    let chat = try resolveChatGUID(values: values, storeFactory: storeFactory)
    guard let pollGuid = values.option("poll")?.trimmingCharacters(in: .whitespacesAndNewlines),
      !pollGuid.isEmpty
    else {
      throw ParsedValuesError.missingOption("poll")
    }
    let resolved = try resolveOptionID(
      values: values, pollGuid: pollGuid, storeFactory: storeFactory)

    var params: [String: Any] = [
      "chatGuid": chat,
      // Native votes associate to the BARE poll GUID; strip a leading
      // `p:<part>/` reference so the bridge never sends the invalid form.
      "pollMessageGuid": barePollGuid(pollGuid),
      "optionIdentifier": resolved.id,
    ]
    // Carry the resolved option text so callers (OpenClaw's echo guard) can
    // suppress a redundant text reply that just restates the vote.
    if let text = resolved.text, !text.isEmpty {
      params["optionText"] = text
    }

    do {
      let data = try await invokeBridge(.sendPollVote, params)
      // Merge the CLI-resolved option label into the emitted result so callers
      // get it regardless of the injected dylib version (older bridges don't
      // echo optionText). OpenClaw's echo guard reads this to drop a redundant
      // text reply that just restates the vote.
      var merged = data
      if let text = resolved.text, !text.isEmpty,
        (merged["optionText"] as? String)?.isEmpty != false
      {
        merged["optionText"] = text
      }
      let guid = (merged["messageGuid"] as? String) ?? ""
      BridgeOutput.emit(
        merged, runtime: runtime,
        summary: guid.isEmpty ? "vote: queued" : "vote: sent (guid=\(guid))")
    } catch {
      BridgeOutput.emitError(String(describing: error), runtime: runtime)
      throw BridgeOutput.EmittedError()
    }
  }

  /// Resolve exactly one option selector against the poll's stable options.
  private static func resolveOptionID(
    values: ParsedValues,
    pollGuid: String,
    storeFactory: (String) throws -> MessageStore
  ) throws -> (id: String, text: String?) {
    let directID = values.option("optionID")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let indexValue = values.optionInt64("optionIndex")
    let textValue = values.option("option")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectors = [directID?.isEmpty == false, indexValue != nil, textValue?.isEmpty == false]
    guard selectors.contains(true) else {
      throw ParsedValuesError.missingOption("option-id")
    }
    guard selectors.filter({ $0 }).count == 1 else {
      throw ParsedValuesError.invalidOption(
        "choose exactly one of --option-id, --option-index, or --option")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    let options = try store.pollOptions(guid: pollGuid)
    guard !options.isEmpty else {
      throw ParsedValuesError.invalidOption("poll (could not decode options for \(pollGuid))")
    }

    // A direct UUID must still be a real option of the decoded poll — otherwise
    // we would "send" a vote for an arbitrary GUID that is not a poll here.
    if let direct = directID, !direct.isEmpty {
      guard let match = options.first(where: { $0.id == direct }) else {
        throw ParsedValuesError.invalidOption(
          "option-id \(direct) is not an option of poll \(pollGuid)")
      }
      return (match.id, match.text)
    }
    if let index = indexValue {
      guard index >= 1, Int(index) <= options.count else {
        throw ParsedValuesError.invalidOption(
          "option-index \(index) out of range (1...\(options.count))")
      }
      let option = options[Int(index) - 1]
      return (option.id, option.text)
    }
    let text = textValue ?? ""
    guard let match = options.first(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame })
    else {
      let available = options.map { $0.text }.joined(separator: ", ")
      throw ParsedValuesError.invalidOption("option \"\(text)\" (available: \(available))")
    }
    return (match.id, match.text)
  }

  private static func resolveChatGUID(
    values: ParsedValues,
    storeFactory: (String) throws -> MessageStore
  ) throws -> String {
    let chatValue = values.option("chat")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let chatID = values.optionInt64("chatID") ?? Int64(chatValue)
    if let chatID {
      let dbPath = values.option("db") ?? MessageStore.defaultPath
      let store = try storeFactory(dbPath)
      guard let info = try store.chatInfo(chatID: chatID) else {
        throw IMsgError.chatNotFound(chatID: chatID)
      }
      return info.guid.isEmpty ? info.identifier : info.guid
    }
    guard !chatValue.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    return chatValue
  }
}

/// The bare poll GUID a native vote associates to. Strips a leading
/// `p:<part>/` reference (the tapback-style form) if present; a plain GUID is
/// returned unchanged. Shared by the CLI and RPC vote paths.
func barePollGuid(_ guid: String) -> String {
  guard let slash = guid.lastIndex(of: "/") else { return guid }
  let next = guid.index(after: slash)
  guard next < guid.endIndex else { return guid }
  return String(guid[next...])
}
