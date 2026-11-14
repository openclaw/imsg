import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func trackedSendDoesNotTrustAnUnpersistedAcknowledgement() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { try $0.run("ALTER TABLE message ADD COLUMN guid TEXT") }
  let output = TestRPCOutput()
  let guid = "32A0B6C2-90D7-4D99-B367-1483B56C9F79"
  let server = RPCServer(
    store: store, verbose: false, output: output,
    invokeBridge: { action, _ in
      if action == .status { return ["selectors": ["clientMessageGuidReservation": true]] }
      // Messages has rewritten the identity; its acknowledgement still repeats the request.
      return ["messageGuid": guid, "chatGuid": "iMessage;-;+123", "service": "iMessage"]
    }, isBridgeReady: { true })
  await server.handleLineForTesting(
    """
    {"jsonrpc":"2.0","id":1,"method":"send.tracked",
    "params":{"to":"+123","text":"fixture","attempt_id":"\(guid)"}}
    """)
  #expect(output.responses.isEmpty)
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  let data = try #require(error["data"] as? [String: Any])
  #expect(data["disposition"] as? String == "may_have_completed")
  #expect(data["retry_safe"] as? Bool == false)
}

@Test(arguments: ["correct", "wrong-guid", "wrong-chat", "incoming", "old", "unjoined"])
func trackedReceiptRequiresNewOutgoingIdentityInTargetChat(kind: String) async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let guid = "32A0B6C2-90D7-4D99-B367-1483B56C9F79"
  try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run(
      "INSERT INTO chat(ROWID, guid, chat_identifier) VALUES (2, 'iMessage;-;other', 'other')")
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (?, 1, 'fixture', ?, 1, ?, 'iMessage')",
      kind == "old" ? 3 : 99, kind == "wrong-guid" ? "another-guid" : guid.lowercased(),
      kind == "incoming" ? 0 : 1)
    if kind != "unjoined" {
      try db.run(
        "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)",
        kind == "wrong-chat" ? 2 : 1, kind == "old" ? 3 : 99)
    }
  }
  do {
    try await TrackedSendVerifier.verify(
      store: store, guid: guid, chatTarget: "iMessage;-;+123", afterRowID: 5, timeout: 0)
    #expect(kind == "correct")
  } catch let failure as DeliveryFailure {
    #expect(kind != "correct")
    #expect(failure.disposition == .mayHaveCompleted)
    #expect(!failure.retrySafe)
  }
}

@Test
func trackedReceiptWaitsForItsChatJoin() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let guid = "32A0B6C2-90D7-4D99-B367-1483B56C9F79"
  try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (99, 1, 'fixture', ?, 1, 1, 'iMessage')",
      guid)
  }
  var polls = 0
  try await TrackedSendVerifier.verify(
    store: store, guid: guid, chatTarget: "iMessage;-;+123", afterRowID: 5,
    now: { Date(timeIntervalSince1970: Double(polls)) },
    wait: {
      polls += 1
      if polls == 2 {
        _ = try store.withConnection {
          try $0.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 99)")
        }
      }
    })
  #expect(polls == 2)
}
