import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private enum SendCommandServiceDetectionTestError: Error {
  case unavailable
}

@Test
func sendCommandDirectSendDoesNotRequireMessagesDatabase() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "to": ["+436769770569"],
      "text": ["hi"],
      "service": ["auto"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in captured = options },
      resolveSentMessage: { _, _, _, _ in nil },
      storeFactory: { _ in throw SendCommandServiceDetectionTestError.unavailable }
    )
  }

  #expect(captured?.recipient == "+436769770569")
  #expect(captured?.service == .auto)
  #expect(captured?.allowSMSFallback == true)
  #expect(captured?.chatIdentifier.isEmpty == true)
  #expect(captured?.chatGUID.isEmpty == true)
}

@Test
func sendCommandAutoDetectionUsesRegionNormalizedRecipient() async throws {
  let path = try CommandTestDatabase.makePath()
  let db = try Connection(path)
  try db.run("ALTER TABLE handle ADD COLUMN service TEXT")
  try db.run("INSERT INTO handle(ROWID, id, service) VALUES (44, '+447700900000', 'SMS')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (44, 44, 'sms history', ?, 0, 'SMS')
    """,
    CommandTestDatabase.appleEpoch(Date())
  )
  let values = ParsedValues(
    positional: [],
    options: [
      "db": [path],
      "to": ["07700 900000"],
      "file": ["/tmp/photo.jpg"],
      "region": ["GB"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { options in captured = options },
      resolveSentMessage: { _, _, _, _ in nil }
    )
  }
  #expect(captured?.service == .sms)
  #expect(captured?.allowSMSFallback == false)
}
