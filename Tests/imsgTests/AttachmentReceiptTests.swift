import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func attachmentReceiptWaitsForChatAndAttachmentJoins() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let sentAt = Date()
  let path = "/synthetic/Attachments/imsg/attempt-one/photo.jpg"
  _ = try store.withConnection { db in
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (99, 1, '', ?, 1, 'iMessage')",
      CommandTestDatabase.appleEpoch(sentAt))
  }
  var polls = 0
  let receipt = try await SentMessageVerifier.resolveSentMessage(
    store: store,
    options: MessageSendOptions(recipient: "", attachmentPath: path, chatGUID: "iMessage;-;+123"),
    chatID: 1, sentAt: sentAt,
    now: { sentAt.addingTimeInterval(Double(polls) / 10) },
    wait: {
      polls += 1
      try store.withConnection { db in
        if polls == 1 {
          try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 99)")
        } else if polls == 2 {
          try db.run("INSERT INTO attachment(ROWID, filename) VALUES (99, ?)", path)
          try db.run(
            "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (99, 99)")
        }
      }
    })
  #expect(polls == 2)
  #expect(receipt?.rowID == 99)
  #expect(receipt?.chatID == 1)
}

@Test(arguments: [
  "correct", "wrong-chat", "unjoined", "wrong-path", "old", "incoming", "ambiguous",
])
func attachmentReceiptRequiresUniqueStagedPathInTargetChat(kind: String) throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let sentAt = Date()
  let path = "/synthetic/Attachments/imsg/attempt-one/photo.jpg"
  try store.withConnection { db in
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (99, 1, '', ?, ?, 'iMessage')",
      CommandTestDatabase.appleEpoch(sentAt.addingTimeInterval(kind == "old" ? -30 : 0)),
      kind == "incoming" ? 0 : 1)
    if kind != "unjoined" {
      try db.run(
        "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, 99)",
        kind == "wrong-chat" ? 2 : 1)
    }
    try db.run(
      "INSERT INTO attachment(ROWID, filename) VALUES (99, ?)",
      kind == "wrong-path" ? "/synthetic/Attachments/imsg/attempt-two/photo.jpg" : path)
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (99, 99)")
    if kind == "ambiguous" {
      try db.run(
        "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (100, 1, '', ?, 1, 'iMessage')",
        CommandTestDatabase.appleEpoch(sentAt))
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 100)")
      try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (100, 99)")
    }
  }
  let receipt = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store,
    options: MessageSendOptions(recipient: "", attachmentPath: path),
    chatID: 1, since: sentAt.addingTimeInterval(-2))
  #expect(receipt?.rowID == (kind == "correct" ? 99 : nil))
}

@Test
func attachmentReceiptAcceptsHomeRelativePath() throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let sentAt = Date()
  let relativePath = "~/Library/Messages/Attachments/imsg/synthetic/photo.jpg"
  try store.withConnection { db in
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (99, 1, '', ?, 1, 'iMessage')",
      CommandTestDatabase.appleEpoch(sentAt))
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 99)")
    try db.run("INSERT INTO attachment(ROWID, filename) VALUES (99, ?)", relativePath)
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (99, 99)")
  }
  let options = MessageSendOptions(
    recipient: "", attachmentPath: NSString(string: relativePath).expandingTildeInPath)
  #expect(
    try SentMessageVerifier.resolveSentMessageCandidate(
      store: store, options: options, chatID: 1, since: sentAt.addingTimeInterval(-2))?.rowID == 99)
}

@Test
func attachmentReceiptDeadlineKeepsUnjoinedRowUncertain() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let sentAt = Date()
  try store.withConnection { db in
    try db.run("INSERT INTO handle(ROWID, id) VALUES (99, 'iMessage;-;+123')")
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (99, 99, '', ?, 1, 'iMessage')",
      CommandTestDatabase.appleEpoch(sentAt))
  }
  var polls = 0
  do {
    _ = try await SentMessageVerifier.verifyAppleScriptSend(
      store: store,
      options: MessageSendOptions(
        recipient: "", attachmentPath: "/synthetic/photo.jpg", chatGUID: "iMessage;-;+123"),
      chatID: 1, sentAt: sentAt,
      resolve: { store, options, chatID, sentAt in
        try await SentMessageVerifier.resolveSentMessage(
          store: store, options: options, chatID: chatID, sentAt: sentAt,
          now: { sentAt.addingTimeInterval(Double(polls) / 10) }, wait: { polls += 1 })
      })
    Issue.record("expected uncertain delivery after receipt deadline")
  } catch let failure as DeliveryFailure {
    #expect(polls == 80)
    #expect(!failure.retrySafe)
    #expect(failure.disposition == .mayHaveCompleted)
    #expect(failure.description.contains("row (99)"))
  }
}

@Test(arguments: [false, true])
func attachmentReceiptDirectSendReturnsObservedRow(rpc: Bool) async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let path = "/synthetic/Attachments/imsg/attempt-one/photo.jpg"
  let send: (MessageSendOptions) throws -> MessageSendOptions = { options in
    try store.withConnection { db in
      try db.run(
        "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (99, 1, '', ?, 1, 'iMessage')",
        CommandTestDatabase.appleEpoch(Date()))
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 99)")
      try db.run("INSERT INTO attachment(ROWID, filename) VALUES (99, ?)", path)
      try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (99, 99)")
    }
    var staged = options
    staged.attachmentPath = path
    return staged
  }
  if rpc {
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store, verbose: false, output: output, sendMessage: send,
      isBridgeReady: { false })
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":1,"method":"send","params":{"to":"+123","file":"/synthetic/photo.jpg","transport":"applescript"}}"#
    )
    let result = try #require(output.responses.first?["result"] as? [String: Any])
    #expect(result["id"] as? Int64 == 99)
  } else {
    let values = ParsedValues(
      positional: [], options: ["to": ["+123"], "file": ["/synthetic/photo.jpg"]],
      flags: ["jsonOutput"])
    let (output, _) = try await StdoutCapture.capture {
      try await SendCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values), sendMessage: send,
        storeFactory: { _ in store })
    }
    let result = try #require(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(result["id"] as? Int64 == 99)
  }
}
