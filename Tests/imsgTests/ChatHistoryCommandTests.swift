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
  let payload = try commandTestJSONObject(from: output)
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
  let payload = try commandTestJSONObject(from: output)
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
  let payload = try commandTestJSONObject(from: output)
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
  let payload = try commandTestJSONObject(from: output)
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
  let payload = try commandTestJSONObject(from: output)
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
  let payload = try commandTestJSONObject(from: output)
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
