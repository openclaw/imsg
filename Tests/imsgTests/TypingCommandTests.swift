import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import IMsgRPC
@testable import imsg

@Test
func typingCommandRejectsChatAndRecipient() async {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "chatIdentifier": ["iMessage;+;chat123"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await TypingCommand.run(
      values: values,
      runtime: runtime,
      startTyping: { _ in },
      stopTyping: { _ in },
      typeForDuration: { _, _ in }
    )
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description == "Invalid value for option: --to")
  } catch {
    #expect(Bool(false))
  }
}

@Test
func typingCommandRejectsInvalidService() async {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "service": ["fax"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await TypingCommand.run(
      values: values,
      runtime: runtime,
      startTyping: { _ in },
      stopTyping: { _ in },
      typeForDuration: { _, _ in }
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .invalidService(let value):
      #expect(value == "fax")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func typingCommandRejectsInvalidStopOption() async {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "stop": ["1"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await TypingCommand.run(
      values: values,
      runtime: runtime,
      startTyping: { _ in },
      stopTyping: { _ in },
      typeForDuration: { _, _ in }
    )
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description == "Invalid value for option: --stop")
  } catch {
    #expect(Bool(false))
  }
}

@Test
func typingCommandUsesSMSIdentifierForRecipient() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "service": ["sms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var startedIdentifier: String?
  _ = try await StdoutCapture.capture {
    try await TypingCommand.run(
      values: values,
      runtime: runtime,
      startTyping: { identifier in startedIdentifier = identifier },
      stopTyping: { _ in },
      typeForDuration: { _, _ in }
    )
  }
  #expect(startedIdentifier == "SMS;-;+15551234567")
}

@Test
func typingCommandParsesMinuteDuration() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "duration": ["1m"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedDuration: TimeInterval?
  _ = try await StdoutCapture.capture {
    try await TypingCommand.run(
      values: values,
      runtime: runtime,
      startTyping: { _ in },
      stopTyping: { _ in },
      typeForDuration: { _, duration in capturedDuration = duration }
    )
  }
  #expect(capturedDuration == 60)
}
