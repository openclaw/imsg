import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func reactCommandRejectsNoOpAutomation() async throws {
  let (path, _) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"], "reaction": ["like"]], flags: [])
  let output = await StdoutCapture.capture {
    await #expect(throws: DeliveryFailure.self) {
      try await ReactCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        appleScriptRunner: { _, _ in }, confirmationTimeout: .zero)
    }
  }
  #expect(output.output.isEmpty)
  #expect(output.value?.retrySafe == false)
}

@Test
func reactCommandRejectsMultiCharacterEmojiInput() async {
  do {
    let path = try CommandTestDatabase.makePath()
    let values = ParsedValues(
      positional: [],
      options: ["db": [path], "chatID": ["1"], "reaction": ["🎉 party"]],
      flags: []
    )
    let runtime = RuntimeOptions(parsedValues: values)
    try await ReactCommand.run(values: values, runtime: runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .invalidReaction(let value):
      #expect(value == "🎉 party")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func reactCommandBuildsParameterizedAppleScriptForStandardTapback() async throws {
  let (path, db) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedScript = ""
  var capturedArguments: [String] = []
  _ = try await StdoutCapture.capture {
    try await ReactCommand.run(
      values: values,
      runtime: runtime,
      appleScriptRunner: { source, arguments in
        capturedScript = source
        capturedArguments = arguments
        try insertReactEvent(db)
      }
    )
  }
  #expect(capturedArguments == ["iMessage;+;chat123", "Test Chat", "2"])
  #expect(capturedScript.contains("on run argv"))
  #expect(capturedScript.contains("keystroke \"f\" using command down"))
  #expect(capturedScript.contains("set targetChat to chat id chatGUID"))
  #expect(capturedScript.contains("keystroke reactionKey"))
  #expect(capturedScript.contains("keystroke reactionKey\n      delay 0.1\n      key code 36"))
  #expect(capturedScript.contains("chat123") == false)
}

@Test(arguments: ["incoming", "removal", "wrong-type", "wrong-chat", "existing"])
func reactCommandRejectsUnrelatedEvents(kind: String) async throws {
  let (path, db) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  if kind == "existing" { try insertReactEvent(db) }
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: ["jsonOutput"])
  let output = await StdoutCapture.capture {
    await #expect(throws: DeliveryFailure.self) {
      try await ReactCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        appleScriptRunner: { _, _ in
          if kind != "existing" {
            try insertReactEvent(
              db, type: kind == "removal" ? 3001 : kind == "wrong-type" ? 2000 : 2001,
              chatID: kind == "wrong-chat" ? 2 : 1, fromMe: kind != "incoming")
          }
        }, confirmationTimeout: .zero)
    }
  }
  #expect(output.output.isEmpty)
  #expect(output.value?.disposition == .mayHaveCompleted)
}

@Test
func reactCommandWaitsForDelayedChatJoinWithoutRepeatingAutomation() async throws {
  let (path, db) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: ["jsonOutput"])
  var sends = 0
  var waits = 0
  let output = try await StdoutCapture.capture {
    try await ReactCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      appleScriptRunner: { _, _ in
        sends += 1
        try insertReactEvent(db)
        try db.run("DELETE FROM chat_message_join WHERE message_id = 2")
        try insertReactEvent(db, rowID: 3, fromMe: false)
      },
      sleep: { _ in
        waits += 1
        try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
      })
  }
  #expect(sends == 1)
  #expect(waits == 1)
  let result = try JSONDecoder().decode(ReactResult.self, from: Data(output.output.utf8))
  #expect(result.success)
  #expect(result.chatID == 1)
  #expect(result.reactionType == "like")
}

@Test
func reactCommandConfirmsBeyondFirstEventPage() async throws {
  let (path, db) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"], "reaction": ["like"]], flags: [])
  let output = try await StdoutCapture.capture {
    try await ReactCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      appleScriptRunner: { _, _ in
        for rowID in 2...101 { try insertReactEvent(db, rowID: Int64(rowID), fromMe: false) }
        try insertReactEvent(db, rowID: 102)
      })
  }
  #expect(output.output.contains("Sent"))
}

@Test
func reactCommandCancellationAfterAutomationHasUncertainDelivery() async throws {
  let (path, _) = try makeReactDatabase()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"], "reaction": ["like"]], flags: [])
  let failure = await #expect(throws: DeliveryFailure.self) {
    try await ReactCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      appleScriptRunner: { _, _ in }, sleep: { _ in throw CancellationError() })
  }
  #expect(failure?.retrySafe == false)
}

private func makeReactDatabase() throws -> (String, Connection) {
  let path = try CommandTestDatabase.makePath()
  let db = try Connection(path)
  try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
  try db.run("ALTER TABLE message ADD COLUMN associated_message_guid TEXT")
  try db.run("ALTER TABLE message ADD COLUMN associated_message_type INTEGER")
  try db.run("UPDATE message SET guid = 'original-message' WHERE ROWID = 1")
  return (path, db)
}

private func insertReactEvent(
  _ db: Connection, rowID: Int64 = 2, type: Int = 2001, chatID: Int64 = 1, fromMe: Bool = true
) throws {
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service)
    VALUES (?, 1, '', ?, 'p:0/original-message', ?, 1, ?, 'iMessage')
    """, rowID, "reaction-\(rowID)", type, fromMe ? 1 : 0)
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
}

@Test
func reactCommandRejectsCustomEmojiSend() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["🎉"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await ReactCommand.run(
      values: values,
      runtime: runtime,
      appleScriptRunner: { _, _ in
        #expect(Bool(false))
      }
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .unsupportedReaction(let message):
      #expect(message.contains("custom emoji tapback"))
      #expect(message.contains("AppleScript automation"))
      #expect(message.contains("love"))
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}
