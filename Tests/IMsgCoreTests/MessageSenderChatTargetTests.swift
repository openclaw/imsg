import Foundation
import Testing

@testable import IMsgCore

private func capturedArguments(for options: MessageSendOptions) throws -> [String] {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, arguments in captured = arguments })
  try sender.send(options)
  return captured
}

@Test
func messageSenderExplicitGuidWinsOverHandleLikeIdentifier() throws {
  let options = MessageSendOptions(
    recipient: "",
    text: "hi",
    attachmentPath: "",
    service: .auto,
    region: "US",
    chatIdentifier: "imessage:+15551234567",
    chatGUID: "iMessage;+;chat123"
  )
  let captured = try capturedArguments(for: options)

  #expect(captured[5] == "iMessage;+;chat123")
  #expect(captured[6] == "1")
  #expect(captured[0].isEmpty)
}

@Test
func messageSenderUsesChatGuidWhenIdentifierIsGroupHandle() throws {
  let options = MessageSendOptions(
    recipient: "",
    text: "hi",
    attachmentPath: "",
    service: .auto,
    region: "US",
    chatIdentifier: "iMessage;+;group123",
    chatGUID: "iMessage;+;group123"
  )
  let captured = try capturedArguments(for: options)

  #expect(captured[5] == "iMessage;+;group123")
  #expect(captured[6] == "1")
}
