import Commander
import Foundation
import IMsgCore

enum SendCommand {
  static let spec = CommandSpec(
    name: "send",
    abstract: "Send a message (text and/or attachment)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;+;chat...)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(
            label: "service", names: [.long("service")], help: "service to use: imessage|sms|auto"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
        ],
        flags: [
          .make(
            label: "noSMSFallback", names: [.long("no-sms-fallback")],
            help: "disable automatic iMessage->SMS fallback for text-only auto phone sends")
        ]
      )
    ),
    usageExamples: [
      "imsg send --to +14155551212 --text \"hi\"",
      "imsg send --to +14155551212 --text \"hi\" --file ~/Desktop/pic.jpg --service imessage",
      "imsg send --chat-id 1 --text \"hi\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    resolveSentMessage:
      @escaping (
        MessageStore,
        MessageSendOptions,
        Int64?,
        Date
      ) async throws -> Message? = SentMessageVerifier.resolveSentMessage,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    contactResolverFactory: @escaping (String) async -> any ContactResolving = { region in
      await ContactResolver.create(region: region)
    },
    resolveService: @escaping (MessageStore, String, String) -> HandleServiceAvailability = {
      store, handle, region in
      (try? store.preferredService(forHandle: handle, region: region)) ?? .unknown
    }
  ) async throws {
    let region = values.option("region") ?? "US"
    let rawRecipient = values.option("to") ?? ""
    let rawInput = ChatTargetInput(
      recipient: rawRecipient,
      chatID: values.optionInt64("chatID"),
      chatIdentifier: values.option("chatIdentifier") ?? "",
      chatGUID: values.option("chatGUID") ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: rawInput,
      mixedTargetError: ParsedValuesError.invalidOption("to"),
      missingRecipientError: ParsedValuesError.missingOption("to")
    )
    let recipient: String
    if !rawInput.hasChatTarget && ChatTargetResolver.looksLikeContactName(rawRecipient) {
      let contacts = await contactResolverFactory(region)
      recipient = try ChatTargetResolver.resolveRecipientName(rawRecipient, contacts: contacts)
    } else {
      recipient = rawRecipient
    }

    let input = ChatTargetInput(
      recipient: recipient,
      chatID: rawInput.chatID,
      chatIdentifier: rawInput.chatIdentifier,
      chatGUID: rawInput.chatGUID
    )

    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    if text.isEmpty && file.isEmpty {
      throw ParsedValuesError.missingOption("text or file")
    }
    let serviceRaw = values.option("service") ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw IMsgError.invalidService(serviceRaw)
    }

    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store: MessageStore?
    if input.hasChatTarget {
      store = try storeFactory(dbPath)
    } else {
      store = try? storeFactory(dbPath)
    }

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in
        guard let store else {
          throw IMsgError.invalidChatTarget("Messages database unavailable")
        }
        return try store.chatInfo(chatID: chatID)
      },
      unknownChatError: { chatID in
        IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    var effectiveService = service
    if let store, service == .auto && !input.hasChatTarget && !input.recipient.isEmpty {
      switch resolveService(store, input.recipient, region) {
      case .imessage, .unknown:
        effectiveService = .auto
      case .sms:
        effectiveService = .sms
      }
    }

    let directChatInfo: ChatInfo?
    if let store, !input.hasChatTarget {
      directChatInfo = try ChatTargetResolver.existingDirectChat(
        store: store,
        recipient: input.recipient,
        service: effectiveService,
        includeAnyForSMS: service == .auto && effectiveService == .sms
      )
    } else {
      directChatInfo = nil
    }

    let allowSMSFallback =
      service == .auto
      && !input.hasChatTarget
      && !input.recipient.isEmpty
      && !text.isEmpty
      && file.isEmpty
      && !values.flag("noSMSFallback")

    let options = MessageSendOptions(
      recipient: input.recipient,
      text: text,
      attachmentPath: file,
      service: effectiveService,
      region: region,
      chatIdentifier: input.hasChatTarget ? resolvedTarget.chatIdentifier : "",
      chatGUID: input.hasChatTarget ? resolvedTarget.chatGUID : (directChatInfo?.guid ?? ""),
      allowSMSFallback: allowSMSFallback
    )
    let sentAt = Date()
    try sendMessage(options)

    var sentMessage: Message?
    if let store, input.hasChatTarget || !text.isEmpty {
      let verificationChatID =
        input.chatID
        ?? (input.hasChatTarget ? resolvedTarget.preferredIdentifier : nil).flatMap {
          try? store.chatInfo(matchingTarget: $0)?.id
        }
        ?? directChatInfo?.id
      sentMessage = try await SentMessageVerifier.verifyAppleScriptSend(
        store: store,
        options: options,
        chatID: verificationChatID,
        sentAt: sentAt,
        resolve: resolveSentMessage
      )
    }

    if runtime.jsonOutput {
      var payload: [String: Any] = ["status": "sent"]
      if let sentMessage {
        payload["id"] = sentMessage.rowID
        if !sentMessage.guid.isEmpty {
          payload["guid"] = sentMessage.guid
          payload["message_id"] = sentMessage.guid
        }
      }
      try JSONLines.printObject(payload)
    } else {
      StdoutWriter.writeLine("sent")
    }
  }
}
