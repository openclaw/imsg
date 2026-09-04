import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private enum ValidationTestError: Error { case workStarted }

@Test(arguments: ["not-a-number", "9223372036854775808", "", "0"])
func numericReadOptionsRejectInvalidValuesBeforeOpeningDatabase(raw: String) throws {
  let cases: [(arguments: [String], option: String)] = [
    (["chats", "--limit", raw], "limit"),
    (["history", "--chat-id", raw], "chat-id"),
    (["history", "--chat-id", "1", "--limit", raw], "limit"),
    (["watch", "--chat-id", raw], "chat-id"),
    (["watch", "--since-rowid", raw], "since-rowid"),
    (["group", "--chat-id", raw], "chat-id"),
    (["search", "--query", "hello", "--limit", raw], "limit"),
    (["stats", "--chat-id", raw], "chat-id"),
    (["scheduled", "list", "--limit", raw], "limit"),
  ]
  for testCase in cases where raw != "0" || testCase.option != "since-rowid" {
    let result = try runIMsgProcess(
      testCase.arguments + ["--db", "/nonexistent/imsg-validation.db"])
    #expect(result.status == 1)
    #expect(result.output.isEmpty)
    #expect(result.error.contains("Invalid value for option: --\(testCase.option)"))
  }
}

@Test(arguments: ["send", "read", "typing"])
func malformedChatIDCannotFallBackToRecipient(command: String) async throws {
  let spec = try #require(CommandRouter().specs.first { $0.name == command })
  let values = try CommandParser(signature: spec.signature).parse(
    arguments: [
      "--to", "+15550000000", "--chat-id", "invalid",
    ] + (command == "send" ? ["--text", "fixture"] : []))
  let runtime = RuntimeOptions(parsedValues: values)
  var didWork = false
  let store: (String) throws -> MessageStore = { _ in
    didWork = true
    throw ValidationTestError.workStarted
  }
  await expectInvalidOption("chat-id") {
    switch command {
    case "send":
      try await SendCommand.run(
        values: values, runtime: runtime,
        sendMessage: { options in
          didWork = true
          return options
        },
        storeFactory: store)
    case "read":
      try await ReadCommand.run(
        values: values, runtime: runtime, storeFactory: store,
        markAsRead: { _ in didWork = true })
    default:
      try await TypingCommand.run(
        values: values, runtime: runtime, storeFactory: store,
        startTyping: { _ in didWork = true })
    }
  }
  #expect(!didWork)
}

@Test(arguments: ["invalid", "9223372036854775808", "-1"])
func messagePartValidationPrecedesAttachmentStagingAndDispatch(raw: String) async {
  let values = ParsedValues(
    positional: [],
    options: ["chat": ["iMessage;-;+15550000000"], "part": [raw], "file": ["fixture.png"]],
    flags: [])
  var didWork = false
  await expectInvalidOption("part") {
    try await SendRichCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        didWork = true
        return [:]
      },
      stageAttachment: { _ in
        didWork = true
        return "/staged/fixture.png"
      })
  }
  #expect(!didWork)
}

@Test(arguments: ["optionIndex", "chatID"])
func pollRejectsInvalidNumericSelectorsBesideValidAlternatives(label: String) async {
  let values = ParsedValues(
    positional: ["vote"],
    options: [
      "chat": ["iMessage;-;+15550000000"], "poll": ["fixture-poll"],
      "optionID": ["fixture-option"], label: ["invalid"],
    ], flags: [])
  var didWork = false
  await expectInvalidOption(label == "chatID" ? "chat-id" : "option-index") {
    try await PollCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in
        didWork = true
        throw ValidationTestError.workStarted
      },
      invokeBridge: { _, _ in
        didWork = true
        return [:]
      })
  }
  #expect(!didWork)
}

private func expectInvalidOption(
  _ name: String, operation: () async throws -> Void
) async {
  _ = await StdoutCapture.capture {
    do {
      try await operation()
      Issue.record("Expected invalid --\(name) to fail before work")
    } catch ParsedValuesError.invalidOption(let option) {
      #expect(option == name)
    } catch {
      Issue.record("Expected invalid --\(name), got \(error)")
    }
  }
}
