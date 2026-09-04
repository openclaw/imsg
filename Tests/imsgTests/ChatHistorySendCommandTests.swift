import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func chatsCommandRunsWithJsonOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == true)
  #expect(payload["guid"] as? String == "iMessage;+;chat123")
  #expect(payload["display_name"] as? String == "Test Chat")
  #expect(payload["account_id"] as? String == "iMessage;+;me@icloud.com")
  #expect(payload["account_login"] as? String == "me@icloud.com")
  #expect(payload["last_addressed_handle"] as? String == "+15551234567")
  #expect(payload["participants"] as? [String] == ["+123"])
}

@Test
func chatsCommandJsonReportsDirectChatMetadata() async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == false)
  #expect(payload["guid"] as? String == "iMessage;-;+123")
  #expect(payload["display_name"] as? String == "Direct Chat")
  #expect(payload["account_id"] as? String == "iMessage;+;me@icloud.com")
  #expect(payload["account_login"] as? String == "me@icloud.com")
  #expect(payload["last_addressed_handle"] as? String == "+15551234567")
  #expect(payload["participants"] as? [String] == ["+123"])
}

@Test
func historyCommandRunsWithChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == true)
  #expect(payload["chat_identifier"] as? String == "+123")
  #expect(payload["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(payload["chat_name"] as? String == "Test Chat")
  #expect(payload["participants"] as? [String] == ["+123"])
}

@Test
func historyCommandJsonReportsDirectChatMetadata() async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == false)
  #expect(payload["chat_identifier"] as? String == "+123")
  #expect(payload["chat_guid"] as? String == "iMessage;-;+123")
  #expect(payload["chat_name"] as? String == "Direct Chat")
  #expect(payload["participants"] as? [String] == ["+123"])
}

@Test
func searchCommandUsesLocalMessageStore() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "query": ["ell"], "match": ["contains"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await SearchCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["text"] as? String == "hello")
  #expect(payload["chat_id"] as? Int == 1)
}

@Test
func historyCommandRunsWithAttachmentsNonJson() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["attachments"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  _ = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
}

@Test
func historyCommandReportsConvertedAttachmentPath() async throws {
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("gif")
  try Data("gif".utf8).write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "png")
  try FileManager.default.createDirectory(
    at: converted.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("png".utf8).write(to: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let path = try CommandTestDatabase.makePathWithAttachment(
    filename: source.path,
    transferName: "animation.gif",
    uti: "com.compuserve.gif",
    mimeType: "image/gif"
  )
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["attachments", "convertAttachments"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }

  #expect(output.contains("converted_mime=image/png"))
  #expect(output.contains("converted_path=\(converted.path)"))
}

@Test
func chatsCommandRunsWithPlainOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  _ = try await StdoutCapture.capture {
    try await ChatsCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
}

@Test
func chatsCommandIncludesContactNameInJson() async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(names: ["+123": "Alice"])

  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { resolver }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["contact_name"] as? String == "Alice")
  #expect(payload["identifier"] as? String == "+123")
}

@Test
func historyCommandUsesContactNameForPlainIncomingSender() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(names: ["+123": "Alice"])

  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { resolver }
    )
  }
  #expect(output.contains("[recv] Alice: hello"))
}

@Test
func sendCommandRejectsMissingRecipient() async {
  let values = ParsedValues(
    positional: [],
    options: ["text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await SendCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func sendCommandResolvesUniqueContactName() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["Alice"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(
    matches: [ContactMatch(name: "Alice Smith", handle: "+15551234567")]
  )
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      contactResolverFactory: { _ in resolver }
    )
  }
  #expect(captured?.recipient == "+15551234567")
}

@Test
func sendCommandRejectsAmbiguousContactName() async {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["John"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(
    matches: [
      ContactMatch(name: "John Smith", handle: "+15551234567"),
      ContactMatch(name: "John Doe", handle: "+15557654321"),
    ]
  )
  do {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { $0 },
      resolveSentMessage: { _, _, _, _ in nil },
      contactResolverFactory: { _ in resolver }
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    #expect(error.localizedDescription.contains("Multiple contacts match"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func sendCommandRunsWithStubSender() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() }
    )
  }
  #expect(captured?.recipient == "+15551234567")
  #expect(captured?.text == "hi")
}

@Test
func sendCommandResolvesChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture
    )
  }
  #expect(captured?.chatIdentifier == "+123")
  #expect(captured?.chatGUID == "iMessage;+;chat123")
  #expect(captured?.recipient.isEmpty == true)
}

@Test
func sendCommandJsonIncludesResolvedMessageGuidForChatTarget() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "text": ["thread root"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let output = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { $0 },
      resolveSentMessage: { _, options, chatID, _ in
        Message(
          rowID: 42,
          chatID: chatID ?? 0,
          sender: "me@icloud.com",
          text: options.text,
          date: Date(),
          isFromMe: true,
          service: "iMessage",
          handleID: nil,
          attachmentsCount: 0,
          guid: "root-guid"
        )
      }
    )
  }

  let object = try jsonObject(from: output.output)
  #expect(object["status"] as? String == "sent")
  #expect((object["id"] as? NSNumber)?.int64Value == 42)
  #expect(object["guid"] as? String == "root-guid")
  #expect(object["message_id"] as? String == "root-guid")
}

@Test
func sendCommandRejectsMisroutedChatGhost() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "text": ["hi"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  do {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        let db = try Connection(path)
        try db.run("INSERT INTO handle(ROWID, id) VALUES (99, 'iMessage;+;chat123')")
        try db.run(
          """
          INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
          VALUES (99, 99, '', ?, 1, 'SMS')
          """,
          CommandTestDatabase.appleEpoch(Date())
        )
        return options
      },
      resolveSentMessage: { _, _, _, _ in nil }
    )
    #expect(Bool(false))
  } catch let failure as DeliveryFailure {
    #expect(failure.disposition == .mayHaveCompleted)
    #expect(failure.transport == .appleScript)
    #expect(failure.operation == "send")
    #expect(!failure.retrySafe)
    #expect(failure.detail.contains("unjoined empty outgoing row (99)"))
    #expect(failure.description.contains("retry is not safe"))
  }
}

@Test
func sendCommandAutoResolvesToSMSWhenDetected() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"], "service": ["auto"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      resolveService: { _, _, _ in .sms }
    )
  }
  #expect(captured?.service == .sms)
}

@Test
func sendCommandAutoResolvesUnknownToIMessage() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15559998888"], "text": ["hi"], "service": ["auto"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      resolveService: { _, _, _ in .unknown }
    )
  }
  #expect(captured?.service == .auto)
  #expect(captured?.allowSMSFallback == true)
}

@Test
func sendCommandHonorsNoSMSFallbackFlag() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"]],
    flags: ["noSMSFallback"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      resolveService: { _, _, _ in .imessage }
    )
  }
  #expect(captured?.allowSMSFallback == false)
}

@Test
func sendCommandDisablesSMSFallbackForAttachments() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"], "file": ["/tmp/photo.jpg"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      resolveService: { _, _, _ in .imessage }
    )
  }
  #expect(captured?.service == .auto)
  #expect(captured?.allowSMSFallback == false)
}

@Test
func sendCommandExplicitServiceSkipsDetection() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"], "service": ["imessage"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var resolverCalled = false
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in
        captured = options
        return options
      },
      resolveSentMessage: resolvedSentMessageFixture,
      storeFactory: { _ in try CommandTestDatabase.makeStoreForRPC() },
      resolveService: { _, _, _ in
        resolverCalled = true
        return .sms
      }
    )
  }
  #expect(captured?.service == .imessage)
  #expect(captured?.allowSMSFallback == false)
  #expect(resolverCalled == false)
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
