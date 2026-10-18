import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import IMsgRPC
@testable import imsg

@Test
func readCommandRejectsChatAndRecipient() async {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "chatIdentifier": ["iMessage;+;chat123"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await ReadCommand.run(
      values: values,
      runtime: runtime,
      markAsRead: { _ in }
    )
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description == "Invalid value for option: --to")
  } catch {
    #expect(Bool(false))
  }
}

@Test
func readCommandRunsWithRecipient() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedHandle: String?

  _ = try await StdoutCapture.capture {
    try await ReadCommand.run(
      values: values,
      runtime: runtime,
      markAsRead: { handle in capturedHandle = handle }
    )
  }

  #expect(capturedHandle == "+15551234567")
}

@Test
func readCommandResolvesChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedHandle: String?

  _ = try await StdoutCapture.capture {
    try await ReadCommand.run(
      values: values,
      runtime: runtime,
      markAsRead: { handle in capturedHandle = handle }
    )
  }

  #expect(capturedHandle == "iMessage;+;chat123")
}
