import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import IMsgRPC
@testable import imsg

@Test
func groupCommandRequiresChatID() async {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await GroupCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func groupCommandThrowsOnUnknownChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["9999"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await GroupCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    #expect(error.errorDescription?.contains("9999") == true)
  } catch {
    #expect(Bool(false))
  }
}

@Test
func groupCommandPrintsPlainTextForGroup() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await GroupCommand.spec.run(values, runtime)
  }
  #expect(output.contains("id: 1"))
  #expect(output.contains("identifier: +123"))
  #expect(output.contains("guid: iMessage;+;chat123"))
  #expect(output.contains("name: Test Chat"))
  #expect(output.contains("service: iMessage"))
  #expect(output.contains("account_id: iMessage;+;me@icloud.com"))
  #expect(output.contains("account_login: me@icloud.com"))
  #expect(output.contains("last_addressed_handle: +15551234567"))
  #expect(output.contains("is_group: true"))
  #expect(output.contains("- +123"))
}

@Test
func groupCommandEmitsJsonPayload() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await GroupCommand.spec.run(values, runtime)
  }
  let payload = try jsonObject(from: output)
  #expect(payload["id"] as? Int == 1)
  #expect(payload["identifier"] as? String == "+123")
  #expect(payload["guid"] as? String == "iMessage;+;chat123")
  #expect(payload["name"] as? String == "Test Chat")
  #expect(payload["service"] as? String == "iMessage")
  #expect(payload["account_id"] as? String == "iMessage;+;me@icloud.com")
  #expect(payload["account_login"] as? String == "me@icloud.com")
  #expect(payload["last_addressed_handle"] as? String == "+15551234567")
  #expect(payload["is_group"] as? Bool == true)
  #expect(payload["participants"] as? [String] == ["+123"])
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
