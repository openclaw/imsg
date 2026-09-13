import Commander
import Foundation
import IMsgCore

enum SendRichCommand {
  static let spec = CommandSpec(
    name: "send-rich",
    abstract: "Send a message via the IMCore bridge (effects, replies, subjects)",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Unlike `imsg send`
      which uses AppleScript, this routes through Messages' private API for
      richer features: expressive-send effects, reply targets, subject lines.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "chat", names: [.long("chat")], help: "chat guid (e.g. iMessage;-;+15551234567)"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(label: "url", names: [.long("url")], help: "URL to send as a rich link preview"),
          .make(
            label: "effect", names: [.long("effect")],
            help: "expressive send id (impact, loud, gentle, invisibleink, confetti, …)"),
          .make(label: "subject", names: [.long("subject")], help: "subject line"),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(label: "part", names: [.long("part")], help: "part index (default 0)"),
          .make(
            label: "format",
            names: [.long("format")],
            help: "JSON array of {start,length,styles:[...]} ranges (macOS 15+)"),
          .make(
            label: "formatFile", names: [.long("format-file")],
            help: "path to JSON file containing the format ranges array"),
        ],
        flags: [
          .make(
            label: "noDDScan", names: [.long("no-dd-scan")],
            help: "disable data-detector scan deferral")
        ]
      )
    ),
    usageExamples: [
      "imsg send-rich --chat 'iMessage;-;+15551234567' --text 'hi'",
      "imsg send-rich --chat 'iMessage;-;+15551234567' --reply-to ABCD --file ~/Desktop/pic.jpg",
      "imsg send-rich --chat 'iMessage;-;+15551234567' --text 'BOOM' --effect impact",
      "imsg send-rich --chat 'iMessage;-;+15551234567' --text 'pew pew' --effect lasers",
      "imsg send-rich --chat 'iMessage;-;+15551234567' --url https://imsg.sh",
      "imsg send-rich --chat ... --text 'hello world' --format '[{\"start\":0,\"length\":5,\"styles\":[\"bold\"]}]'",
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
    },
    resolveSentMessage:
      @escaping (
        MessageStore,
        MessageSendOptions,
        Int64?,
        Date
      ) async throws -> Message? = SentMessageVerifier.resolveSentMessage,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    stageAttachment: @escaping (String) throws -> String = MessageSender
      .stageAttachmentForMessagesApp,
    prepareRichLink: @escaping RichLinkPrepare = { rawURL in
      try await RichLinkPreparer.prepare(rawURL)
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let part = try values.optionInt("part", minimum: 0) ?? 0
    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    let richLinkURL = values.option("url")
    let preparedRichLink: PreparedRichLinkPreview?
    if let richLinkURL {
      try validateRichLinkOptions(values: values, chat: chat)
      try validateRichLinkChat(
        chat,
        dbPath: values.option("db") ?? MessageStore.defaultPath,
        storeFactory: storeFactory
      )
      let status = try await invokeBridge(.status, [:])
      guard bridgeSupportsRichLinks(status) else {
        throw RichLinkPreparationError.unsupportedBridge
      }
      preparedRichLink = try await prepareRichLink(richLinkURL)
    } else {
      preparedRichLink = nil
    }
    defer { preparedRichLink?.removeStagedImage() }
    let effectiveText = preparedRichLink?.originalURL ?? text
    var params: [String: Any] = [
      "chatGuid": chat,
      "message": effectiveText,
      "partIndex": preparedRichLink == nil ? part : 0,
      "ddScan": preparedRichLink == nil ? !values.flag("noDDScan") : true,
    ]
    if let preparedRichLink {
      params["richLinkPreview"] = preparedRichLink.bridgePayload
    }
    if let effect = values.option("effect"), !effect.isEmpty {
      params["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject = values.option("subject"), !subject.isEmpty { params["subject"] = subject }
    if let reply = values.option("replyTo"), !reply.isEmpty {
      params["selectedMessageGuid"] = reply
    }

    // Optional text formatting (macOS 15+ — Sequoia and later). Pass either
    // inline JSON via --format or a file path via --format-file. Format:
    //   [{"start":0,"length":5,"styles":["bold","italic"]}, ...]
    let formatRaw: String?
    if let inline = values.option("format"), !inline.isEmpty {
      formatRaw = inline
    } else if let path = values.option("formatFile"), !path.isEmpty {
      formatRaw = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      formatRaw = nil
    }
    if let raw = formatRaw {
      guard
        let bytes = raw.data(using: .utf8),
        let ranges = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
      else {
        throw ParsedValuesError.invalidOption("format")
      }
      params["textFormatting"] = ranges
    }

    if !file.isEmpty {
      let expanded = (file as NSString).expandingTildeInPath
      params["filePath"] = try stageAttachment(expanded)
      params["isAudioMessage"] = false
      _ = try await BridgeOutput.invokeAndEmit(
        action: .sendAttachment,
        params: params,
        runtime: runtime,
        invokeBridge: invokeBridge
      ) { data in
        let guid = (data["messageGuid"] as? String) ?? ""
        return guid.isEmpty ? "send-rich: attachment queued" : "send-rich: sent (guid=\(guid))"
      }
      return
    }

    do {
      let sentAt = Date()
      let action: BridgeAction = preparedRichLink == nil ? .sendMessage : .sendRichLink
      let data = try await invokeBridge(action, params)
      let enriched = try await enrichedSentMessageResponse(
        data,
        chat: chat,
        text: effectiveText,
        dbPath: values.option("db") ?? MessageStore.defaultPath,
        sentAt: sentAt,
        resolveSentMessage: resolveSentMessage,
        storeFactory: storeFactory
      )
      let guid = (enriched["messageGuid"] as? String) ?? ""
      let summary = guid.isEmpty ? "send-rich: queued" : "send-rich: sent (guid=\(guid))"
      BridgeOutput.emit(enriched, runtime: runtime, summary: summary)
    } catch {
      BridgeOutput.emitError(String(describing: error), runtime: runtime)
      throw BridgeOutput.EmittedError()
    }
  }

}

// MARK: - send-multipart
