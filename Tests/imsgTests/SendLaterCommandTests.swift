import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func sendLaterValues(_ extra: [String: [String]]) -> ParsedValues {
  var options: [String: [String]] = [
    "chat": ["iMessage;-;+15551234567"],
    "text": ["see you at nine"],
  ]
  options.merge(extra) { _, new in new }
  return ParsedValues(positional: [], options: options, flags: [])
}

@Test
func sendRichSendAtPassesTheDeliveryTimeToTheBridge() async throws {
  let values = sendLaterValues(["sendAt": ["2030-03-17T17:46:40Z"]])
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "scheduled-guid", "sendAt": 1_900_000_000]
      }
    )
  }

  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["sendAt"] as? Double == 1_900_000_000)
  #expect(capturedParams["message"] as? String == "see you at nine")
}

@Test
func sendRichSendAtRejectsATimeItCannotParse() async throws {
  let values = sendLaterValues(["sendAt": ["tomorrow at nine"]])
  var bridgeCalled = false

  await #expect(throws: IMsgError.self) {
    try await SendRichCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        bridgeCalled = true
        return [:]
      }
    )
  }
  #expect(!bridgeCalled)
}

@Test
func sendRichSendAtRefusesAttachments() async throws {
  let values = sendLaterValues([
    "sendAt": ["2030-03-17T17:46:40Z"],
    "file": ["/nonexistent/picture.jpg"],
  ])
  var bridgeCalled = false

  await #expect(throws: ParsedValuesError.self) {
    try await SendRichCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        bridgeCalled = true
        return [:]
      }
    )
  }
  #expect(!bridgeCalled)
}
