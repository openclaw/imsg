import Commander
import Foundation
import IMsgCore

enum HistoryCommand {
  static let spec = CommandSpec(
    name: "history",
    abstract: "Show recent messages for a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid from 'imsg chats'"),
          .make(label: "limit", names: [.long("limit")], help: "Number of messages to show"),
          .make(
            label: "participants", names: [.long("participants")],
            help: "filter by participant handles", parsing: .upToNextOption),
          .make(label: "start", names: [.long("start")], help: "ISO8601 start (inclusive)"),
          .make(label: "end", names: [.long("end")], help: "ISO8601 end (exclusive)"),
        ],
        flags: [
          .make(
            label: "attachments", names: [.long("attachments")], help: "include attachment metadata"
          ),
          .make(
            label: "convertAttachments", names: [.long("convert-attachments")],
            help: "convert CAF/GIF attachments to model-compatible cached files"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg history --chat-id 1 --limit 10 --attachments",
      "imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    contactResolverFactory: @escaping () async -> any ContactResolving = {
      await ContactResolver.create(accessPolicy: .skipIfNotDetermined)
    }
  ) async throws {
    guard let chatID = values.optionInt64("chatID") else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 50
    let showAttachments = values.flag("attachments")
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: values.flag("convertAttachments"))
    let participants = values.optionValues("participants")
      .flatMap { $0.split(separator: ",").map { String($0) } }
      .filter { !$0.isEmpty }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: values.option("start"),
      endISO: values.option("end")
    )

    let store = try MessageStore(path: dbPath)
    let filtered = try store.messages(chatID: chatID, limit: limit, filter: filter)
    let contacts = await contactResolverFactory()

    if runtime.jsonOutput {
      let cache = ChatCache(store: store)
      let attachmentsByMessageID = try store.attachments(
        for: filtered.map(\.rowID),
        options: attachmentOptions
      )
      let reactionsByMessageID = try store.reactions(for: filtered)
      for message in filtered {
        let payload = try await buildMessagePayload(
          store: store,
          cache: cache,
          message: message,
          includeAttachments: true,
          includeReactions: true,
          prefetchedAttachments: attachmentsByMessageID[message.rowID] ?? [],
          prefetchedReactions: reactionsByMessageID[message.rowID] ?? [],
          attachmentOptions: attachmentOptions,
          contactResolver: contacts
        )
        try JSONLines.printObject(payload)
      }
      return
    }

    for message in filtered {
      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      let sender =
        message.isFromMe
        ? message.sender : (contacts.displayName(for: message.sender) ?? message.sender)
      let body = message.poll.map { pollDisplayText(for: $0) } ?? message.text
      StdoutWriter.writeLine("\(timestamp) [\(direction)] \(sender): \(body)")
      if message.attachmentsCount > 0 {
        if showAttachments {
          let metas = try store.attachments(for: message.rowID, options: attachmentOptions)
          for meta in metas {
            StdoutWriter.writeLine(attachmentMetadataLine(for: meta))
          }
        } else {
          StdoutWriter.writeLine(
            "  (\(message.attachmentsCount) attachment\(pluralSuffix(for: message.attachmentsCount)))"
          )
        }
      }
    }
  }
}
