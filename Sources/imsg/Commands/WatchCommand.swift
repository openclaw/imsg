import Commander
import Foundation
import IMsgCore

enum WatchCommand {
  /// Same TTY rule as RPC: headless stdin must not prompt for Contacts.
  static func contactsAccessPolicy(stdinIsTTY: Bool) -> ContactsAccessPolicy {
    .forStdin(isTTY: stdinIsTTY)
  }

  static let spec = CommandSpec(
    name: "watch",
    abstract: "Stream incoming messages",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "limit to chat rowid"),
          .make(
            label: "debounce", names: [.long("debounce")],
            help: "debounce interval for filesystem events (e.g. 250ms)"),
          .make(
            label: "sinceRowID", names: [.long("since-rowid")],
            help: "start watching after this rowid"),
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
          .make(
            label: "reactions", names: [.long("reactions")],
            help: "include reaction events (tapback add/remove) in the stream"
          ),
          .make(
            label: "bbEvents", names: [.long("bb-events")],
            help: "include dylib-pushed events (typing, alias-removed) when injection is active"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg watch --chat-id 1 --attachments --debounce 250ms",
      "imsg watch --chat-id 1 --participants +15551234567",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    contactResolverFactory: @escaping () async -> any ContactResolving = {
      await ContactResolver.create(
        accessPolicy: contactsAccessPolicy(stdinIsTTY: ContactsAccessPolicy.stdinIsTTY)
      )
    },
    streamProvider:
      @escaping (
        MessageWatcher,
        Int64?,
        Int64?,
        MessageWatcherConfiguration,
        MessageFilter
      ) -> AsyncThrowingStream<Message, Error> = {
        watcher, chatID, sinceRowID, config, filter in
        watcher.stream(
          chatID: chatID,
          sinceRowID: sinceRowID,
          configuration: config,
          filter: filter
        )
      },
    bridgeStreamProvider:
      @escaping (String) throws -> AsyncThrowingStream<IMsgEventTailer.Event, Error> = { path in
        IMsgEventTailer(path: path, createIfMissing: true).events()
      }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatID = try values.optionChatID()
    let debounceString = values.option("debounce") ?? "250ms"
    guard let debounceInterval = DurationParser.parse(debounceString) else {
      throw ParsedValuesError.invalidOption("debounce")
    }
    let sinceRowID = try values.optionInt64("sinceRowID", name: "since-rowid")
    let showAttachments = values.flag("attachments")
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: values.flag("convertAttachments"))
    let includeReactions = values.flag("reactions")
    let participants = values.optionValues("participants")
      .flatMap { $0.split(separator: ",").map { String($0) } }
      .filter { !$0.isEmpty }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: values.option("start"),
      endISO: values.option("end")
    )

    let store = try storeFactory(dbPath)
    let watcher = MessageWatcher(store: store)
    let contacts = await contactResolverFactory()
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      batchLimit: 100,
      includeReactions: includeReactions
    )

    let stream = streamProvider(watcher, chatID, sinceRowID, config, filter)
    let emitMessage: @Sendable (Message) throws -> Void = { message in
      if runtime.jsonOutput {
        let payload = try buildMessagePayload(
          store: store,
          message: message,
          includeAttachments: true,
          includeReactions: true,
          attachmentOptions: attachmentOptions,
          contactResolver: contacts
        )
        try JSONLines.printObject(payload)
        return
      }
      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      let sender =
        message.isFromMe
        ? message.sender : (contacts.displayName(for: message.sender) ?? message.sender)
      if message.isReaction, let reactionType = message.reactionType {
        let action = (message.isReactionAdd ?? true) ? "added" : "removed"
        let targetGUID = message.reactedToGUID ?? "unknown"
        StdoutWriter.writeLine(
          "\(timestamp) [\(direction)] \(sender) \(action) \(reactionType.emoji) reaction to \(targetGUID)"
        )
        return
      }
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

    func watchDatabase() async throws {
      for try await message in stream {
        try Task.checkCancellation()
        try emitMessage(message)
      }
    }

    guard values.flag("bbEvents") else {
      try await watchDatabase()
      return
    }

    let bridgeStream = try? bridgeStreamProvider(MessagesLauncher.shared.bridgeEventsFile)
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      if let bridgeStream {
        group.addTask {
          do {
            for try await event in bridgeStream {
              try Task.checkCancellation()
              if runtime.jsonOutput {
                var object: [String: Any] = [
                  "kind": "bridge-event",
                  "event": event.name,
                  "data": event.decodedPayload(),
                ]
                if let timestamp = event.timestamp { object["ts"] = timestamp }
                try JSONLines.printObject(object)
              } else {
                let timestamp = event.timestamp ?? CLIISO8601.format(Date())
                StdoutWriter.writeLine("\(timestamp) [bridge] \(event.name)")
              }
            }
          } catch {}
        }
      }

      try await watchDatabase()
      try Task.checkCancellation()
    }
  }
}
