import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcForcedAppleScriptUsesExistingDirectChatAndVerifiesText() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  try setAnyDirectChat(store)
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  var verifiedChatID: Int64?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { captured = $0 },
    resolveSentMessage: { _, options, chatID, _ in
      verifiedChatID = chatID
      return sentMessage(options: options, chatID: chatID)
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"direct","method":"send","params":{"to":"+123","text":"nonce","service":"imessage","transport":"applescript"}}"#
  )

  #expect(captured?.recipient == "+123")
  #expect(captured?.chatIdentifier.isEmpty == true)
  #expect(captured?.chatGUID == "any;-;+123")
  #expect(captured?.service == .imessage)
  #expect(verifiedChatID == 1)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "applescript")
  #expect(result?["guid"] as? String == "verified-guid")
}

@Test
func sendCommandUsesExistingDirectChatAndVerifiesText() async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let db = try Connection(path)
  try db.run("UPDATE chat SET guid = 'any;-;+123', service_name = 'iMessage' WHERE ROWID = 1")
  let values = ParsedValues(
    positional: [],
    options: [
      "db": [path],
      "to": ["+123"],
      "text": ["nonce"],
      "service": ["imessage"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  var verifiedChatID: Int64?

  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { captured = $0 },
      resolveSentMessage: { _, options, chatID, _ in
        verifiedChatID = chatID
        return sentMessage(options: options, chatID: chatID)
      }
    )
  }

  #expect(captured?.recipient == "+123")
  #expect(captured?.chatIdentifier.isEmpty == true)
  #expect(captured?.chatGUID == "any;-;+123")
  #expect(captured?.service == .imessage)
  #expect(verifiedChatID == 1)
}

@Test
func newRecipientVerificationIgnoresUnrelatedSameTextSend() throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let now = Date()
  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (90, 1, 'same text', ?, 1, 'iMessage')
      """,
      CommandTestDatabase.appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 90)")
  }
  let options = MessageSendOptions(
    recipient: "+999",
    text: "same text",
    service: .imessage,
    allowSMSFallback: false
  )

  let unrelated = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store,
    options: options,
    chatID: nil,
    since: now.addingTimeInterval(-1)
  )
  #expect(unrelated == nil)

  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (2, '+999', 'iMessage;-;+999', 'New Direct Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (99, '+999')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (2, 99)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (99, 99, 'same text', ?, 1, 'iMessage')
      """,
      CommandTestDatabase.appleEpoch(now.addingTimeInterval(1))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 99)")
  }

  let intended = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store,
    options: options,
    chatID: nil,
    since: now.addingTimeInterval(-1)
  )
  #expect(intended?.rowID == 99)
  #expect(intended?.chatID == 2)
}

@Test
func rpcAppleScriptSuccessWithoutTextRowReturnsOutcomeUnknown() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"missing","method":"send","params":{"to":"+123","text":"private-nonce","transport":"applescript"}}"#
  )

  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(error?["code"] as? Int == -32001)
  #expect(data?["retry_safe"] as? Bool == false)
  #expect(data?["disposition"] as? String == "may_have_completed")
  #expect(data?["transport"] as? String == "applescript")
  #expect(data?["operation"] as? String == "send")
  #expect((data?["detail"] as? String)?.contains("no matching outgoing text row") == true)
  #expect(!String(describing: error).contains("private-nonce"))
}

@Test
func sendCommandSuccessWithoutTextRowThrowsTypedUncertainty() async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "to": ["+123"], "text": ["nonce"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  do {
    try await SendCommand.run(
      values: values,
      runtime: runtime,
      sendMessage: { _ in },
      resolveSentMessage: { _, _, _, _ in nil }
    )
    Issue.record("expected unconfirmed delivery failure")
  } catch let failure as DeliveryFailure {
    #expect(failure.disposition == .mayHaveCompleted)
    #expect(failure.transport == .appleScript)
    #expect(failure.operation == "send")
    #expect(!failure.retrySafe)
    #expect(failure.description.contains("retry is not safe"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test
func directChatGhostKeepsExistingDiagnosticAheadOfNoRowUncertainty() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  try setAnyDirectChat(store)
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in
      try store.withConnection { db in
        try db.run("INSERT INTO handle(ROWID, id) VALUES (99, 'any;-;+123')")
        try db.run(
          """
          INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
          VALUES (99, 99, '', ?, 1, 'SMS')
          """,
          CommandTestDatabase.appleEpoch(Date())
        )
      }
    },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"ghost","method":"send","params":{"to":"+123","text":"nonce","transport":"applescript"}}"#
  )

  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(error?["code"] as? Int == -32001)
  #expect(data?["retry_safe"] as? Bool == false)
  #expect(data?["disposition"] as? String == "may_have_completed")
  #expect(data?["transport"] as? String == "applescript")
  #expect(data?["operation"] as? String == "send")
  #expect((data?["detail"] as? String)?.contains("unjoined empty outgoing row (99)") == true)
}

private func setAnyDirectChat(_ store: MessageStore) throws {
  _ = try store.withConnection { db in
    try db.run(
      "UPDATE chat SET chat_identifier = '+123', guid = 'any;-;+123', service_name = 'iMessage' WHERE ROWID = 1"
    )
  }
}

private func sentMessage(options: MessageSendOptions, chatID: Int64?) -> Message {
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
    guid: "verified-guid"
  )
}
