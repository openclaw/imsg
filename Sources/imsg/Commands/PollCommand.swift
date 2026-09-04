import Commander
import Foundation
import IMsgCore

enum PollCommand {
  static let spec = CommandSpec(
    name: "poll",
    abstract: "Send a native Apple Messages poll",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Use the `send`
      action to create a native Messages Polls extension balloon, `vote`/`unvote`
      to select or remove a selection.

      Messages renders only the options on a poll balloon — the poll title is
      never shown to recipients. So `send` automatically sends `--question` as a
      plain caption message right after the poll (matching how the native
      "comment or Send" field renders — a message with no thread metadata, not a
      threaded reply). Callers pass only `--question` and the visible caption
      appears for free; `--comment` overrides the caption text when it should
      differ from the title. Use `--no-comment` when the caller renders its own
      visible context before the poll.

      The caption is best-effort but not silent: the result reports it under
      `comment` (`requested`, `sent`, `verified`, plus
      `error`/`disposition`/`retry_safe` when it fails or remains unresolved). A bridge
      acknowledgement is not proof of delivery, so the caption's row is looked
      up in the target chat before `sent` is reported true. `sent: null` means
      delivery is unknown and must not be retried automatically. Re-send the
      caption text alone only when `retry_safe` is true; never re-send the poll,
      which would duplicate the balloon.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "send|vote|unvote", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid or rowid"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "question", names: [.long("question")],
            help:
              "poll question. Messages does not render the poll title on the balloon, so imsg "
              + "sends this as a plain caption message right after the poll (the visible text) "
              + "and also stores it as the payload title for agent readback"
          ),
          .make(
            label: "comment", names: [.long("comment")],
            help:
              "optional override for the caption text; defaults to --question. Sent as a plain "
              + "message right after the poll, matching Messages' native 'comment or Send' field"
          ),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(
            label: "option", names: [.long("option")],
            help: "poll option text; pass at least twice"),
          .make(
            label: "poll", names: [.long("poll")],
            help: "vote/unvote: guid of the poll message to update"),
          .make(
            label: "optionID", names: [.long("option-id")],
            help: "vote/unvote: UUID of the option to select"),
          .make(
            label: "optionIndex", names: [.long("option-index")],
            help: "vote/unvote: 1-based option number to select"),
        ],
        flags: [
          .make(
            label: "noComment", names: [.long("no-comment")],
            help: "do not echo the question as a caption after the poll"
          )
        ]
      )
    ),
    usageExamples: [
      "imsg poll send --chat 'iMessage;-;+15551234567' --question 'Dinner?' --option 'Pizza' --option 'Sushi'",
      "imsg poll send --chat 'iMessage;-;+15551234567' --question 'Dinner?' --comment 'Vote by 5pm 🍽️' --option 'Pizza' --option 'Sushi'",
      "imsg poll send --chat 'iMessage;-;+15551234567' --reply-to ABCD --question 'Approve?' --option 'Yes' --option 'No'",
      "imsg poll vote --chat 'iMessage;-;+15551234567' --poll ABCD --option-id 1B2C-...",
      "imsg poll unvote --chat 'iMessage;-;+15551234567' --poll ABCD --option-index 1",
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
    },
    verifyCaption: ((_ captionGUID: String) async -> PollCaptionStatus.VerificationOutcome)? = nil
  ) async throws {
    switch values.argument(0) {
    case "send":
      try await runSend(
        values: values, runtime: runtime, storeFactory: storeFactory, invokeBridge: invokeBridge,
        verifyCaption: verifyCaption)
    case "vote":
      try await runVote(
        remove: false,
        values: values, runtime: runtime, storeFactory: storeFactory, invokeBridge: invokeBridge)
    case "unvote":
      try await runVote(
        remove: true,
        values: values, runtime: runtime, storeFactory: storeFactory, invokeBridge: invokeBridge)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  private static func runSend(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any],
    verifyCaption: ((_ captionGUID: String) async -> PollCaptionStatus.VerificationOutcome)? = nil
  ) async throws {
    if values.option("comment") != nil, values.flag("noComment") {
      throw ParsedValuesError.invalidOption("comment")
    }
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

    // Messages renders only the poll options on the balloon — the poll title
    // (payload item.title) is never shown to recipients. To make the poll's
    // question visible we send it as a PLAIN caption message right after the
    // poll, matching how the native "comment or Send" field renders. It is NOT
    // a threaded reply: native poll comments carry no thread metadata, so a
    // reply (which sets thread_originator) would decorate the poll balloon with
    // a reply connector. Outbound (from_me) rows are cached and never
    // re-processed downstream, so no poll<->comment link is needed on our sends.
    // Callers set only --question; the caption comes for free, so agents need no
    // knowledge of this. --comment overrides the echoed text.
    let comment = values.option("comment").flatMap { $0.isEmpty ? nil : $0 } ?? question
    let wantsComment = !values.flag("noComment") && !comment.isEmpty
    // A bridge acknowledgement is not proof the caption row persisted, so look
    // for it. `try?`: an unreadable database means we simply do not check, and
    // must never turn that into a delivery claim either way.
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let verifier =
      verifyCaption
      ?? { captionGUID in
        // Opened lazily: a suppressed caption must not pay for a database open.
        await PollCaptionStatus.verifyCaption(
          captionGUID: captionGUID, chatGUID: chat, store: try? storeFactory(dbPath))
      }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendPoll,
      params: params,
      runtime: runtime,
      invokeBridge: invokeBridge,
      finalize: { data in
        await PollCaptionStatus.sendCaption(
          after: data,
          chat: chat,
          comment: wantsComment ? comment : nil,
          invokeBridge: invokeBridge,
          verify: verifier
        )
      },
      summary: sendSummary
    )
  }

  /// Call out a confirmed caption failure or an unresolved outcome without
  /// turning uncertainty into unsafe retry advice.
  private static func sendSummary(_ data: [String: Any]) -> String {
    let guid = (data["messageGuid"] as? String) ?? ""
    let base = guid.isEmpty ? "poll: queued" : "poll: sent (guid=\(guid))"
    guard let status = data["comment"] as? [String: Any] else { return base }
    if PollCaptionStatus.isDeliveryUnknown(status) {
      return "\(base); caption delivery UNKNOWN; do not retry automatically"
    }
    guard PollCaptionStatus.isUndelivered(status) else { return base }
    if (status["retry_safe"] as? Bool) == true {
      return "\(base); caption NOT delivered; re-send the caption only, never the poll"
    }
    return "\(base); caption NOT delivered; automatic retry is not known to be safe"
  }

  private static func runVote(
    remove: Bool,
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async throws {
    try validateOptionSelector(values)
    let chat = try resolveChatGUID(values: values, storeFactory: storeFactory)
    guard let pollGuid = values.option("poll")?.trimmingCharacters(in: .whitespacesAndNewlines),
      !pollGuid.isEmpty
    else {
      throw ParsedValuesError.missingOption("poll")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    let resolved = try resolveOptionID(
      values: values, pollGuid: pollGuid, store: store)

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
    if remove {
      let selectedOptionIDs = try store.pollSelectedOptionIDs(guid: pollGuid)
      guard selectedOptionIDs.contains(resolved.id) else {
        throw ParsedValuesError.invalidOption(
          "option-id \(resolved.id) is not currently selected")
      }
      params["remainingOptionIdentifiers"] = selectedOptionIDs.filter { $0 != resolved.id }
    }

    do {
      let action: BridgeAction = remove ? .sendPollUnvote : .sendPollVote
      let data = try await invokeBridge(action, params)
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
        summary: guid.isEmpty
          ? "\(remove ? "unvote" : "vote"): queued"
          : "\(remove ? "unvote" : "vote"): sent (guid=\(guid))")
    } catch {
      BridgeOutput.emitError(String(describing: error), runtime: runtime)
      throw BridgeOutput.EmittedError()
    }
  }

  /// Resolve exactly one option selector against the poll's stable options.
  private static func validateOptionSelector(_ values: ParsedValues) throws {
    let directID = values.option("optionID")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let indexValue = try values.optionInt64("optionIndex", name: "option-index", minimum: 1)
    let textValue = values.option("option")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectors = [directID?.isEmpty == false, indexValue != nil, textValue?.isEmpty == false]
    guard selectors.contains(true) else {
      throw ParsedValuesError.missingOption("option-id")
    }
    guard selectors.filter({ $0 }).count == 1 else {
      throw ParsedValuesError.invalidOption(
        "choose exactly one of --option-id, --option-index, or --option")
    }
  }

  private static func resolveOptionID(
    values: ParsedValues,
    pollGuid: String,
    store: MessageStore
  ) throws -> (id: String, text: String?) {
    let directID = values.option("optionID")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let indexValue = try values.optionInt64("optionIndex", name: "option-index", minimum: 1)
    let textValue = values.option("option")?.trimmingCharacters(in: .whitespacesAndNewlines)
    try validateOptionSelector(values)
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
    let chatID = try values.optionChatID() ?? Int64(chatValue)
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
