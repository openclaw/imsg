import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func neutralReceiptChangesPreserveExistingStoreCallables() throws {
  let store = try neutralReceiptStore(service: .sms)
  let now = Date()
  try insertNeutralReceipt(store, id: 90, service: "iMessage", date: now)
  let findText: (String, Int64?, Date) throws -> Message? = store.latestSentMessage
  let findAttachment: (String, Int64, Date) throws -> Message? = store.sentAttachmentReceipt
  #expect(try findText("nonce", 1, now.addingTimeInterval(-1))?.rowID == 90)
  #expect(try findAttachment("/tmp/no-attachment.png", 1, now) == nil)
}

@Test(arguments: [MessageService.sms, .imessage], [false, true])
func neutralReceiptMatchesEffectiveService(service: MessageService, explicitChat: Bool) throws {
  let store = try neutralReceiptStore(service: service)
  let now = Date()
  let wanted = service == .sms ? "SMS" : "iMessage"
  let opposite = service == .sms ? "iMessage" : "SMS"
  let options = MessageSendOptions(recipient: "+123", text: "nonce", service: service)
  let chatID: Int64? = explicitChat ? 1 : nil

  // An opposite-service receipt exists while the intended send is still missing.
  try insertNeutralReceipt(store, id: 90, service: opposite, date: now)
  #expect(
    try SentMessageVerifier.resolveSentMessageCandidate(
      store: store, options: options, chatID: chatID, since: now.addingTimeInterval(-2)) == nil)

  // A newer, same-text, opposite-service row must not hide the intended receipt.
  try insertNeutralReceipt(store, id: 91, service: wanted, date: now.addingTimeInterval(-1))
  let receipt = try #require(
    try SentMessageVerifier.resolveSentMessageCandidate(
      store: store, options: options, chatID: chatID, since: now.addingTimeInterval(-2)))
  #expect(receipt.rowID == 91)
  #expect(receipt.guid == "neutral-91")
  #expect(receipt.service == wanted)
}

@Test(arguments: [MessageService.auto, .imessage])
func neutralReceiptSupportsIMessageLite(service: MessageService) throws {
  let store = try neutralReceiptStore(service: .imessage)
  let now = Date()
  try insertNeutralReceipt(store, id: 90, service: "iMessageLite", date: now)
  let receipt = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store, options: MessageSendOptions(recipient: "+123", text: "nonce", service: service),
    chatID: nil, since: now.addingTimeInterval(-1))
  #expect(receipt?.rowID == 90)
}

@Test(arguments: ["RCS", "rcs"])
func neutralSMSReceiptSupportsRelayRCS(receiptService: String) throws {
  let store = try neutralReceiptStore(service: .sms)
  let now = Date()
  try insertNeutralReceipt(store, id: 90, service: receiptService, date: now)
  let path = "/tmp/imsg-rcs-receipt.png"
  try store.withConnection { db in
    try db.run("INSERT INTO attachment(ROWID, filename) VALUES (90, ?)", path)
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (90, 90)")
  }
  for attachmentOnly in [false, true] {
    for requested in [MessageService.sms, .imessage] {
      let receipt = try SentMessageVerifier.resolveSentMessageCandidate(
        store: store,
        options: MessageSendOptions(
          recipient: "+123", text: attachmentOnly ? "" : "nonce",
          attachmentPath: attachmentOnly ? path : "", service: requested),
        chatID: 1, since: now.addingTimeInterval(-1))
      if requested == .sms {
        #expect(receipt?.rowID == 90)
        #expect(receipt?.service == receiptService)
      } else {
        #expect(receipt == nil)
      }
    }
  }
}

@Test(arguments: [MessageService.sms, .imessage])
func neutralAttachmentReceiptMatchesEffectiveService(service: MessageService) throws {
  let store = try neutralReceiptStore(service: service)
  let now = Date()
  let wanted = service == .sms ? "SMS" : "iMessage"
  let opposite = service == .sms ? "iMessage" : "SMS"
  let path = "/tmp/imsg-receipt-fixture.png"
  try insertNeutralReceipt(store, id: 90, service: opposite, date: now)
  try store.withConnection { db in
    try db.run("INSERT INTO attachment(ROWID, filename) VALUES (90, ?)", path)
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (90, 90)")
  }
  let options = MessageSendOptions(recipient: "+123", attachmentPath: path, service: service)
  #expect(
    try SentMessageVerifier.resolveSentMessageCandidate(
      store: store, options: options, chatID: nil, since: now.addingTimeInterval(-1)) == nil)
  _ = try store.withConnection { db in
    try db.run("UPDATE message SET service = ? WHERE ROWID = 90", wanted)
  }
  let receipt = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store, options: options, chatID: nil, since: now.addingTimeInterval(-1))
  #expect(receipt?.rowID == 90)
  #expect(receipt?.service == wanted)
}

@Test(arguments: [false, true])
func neutralMissingSMSFallbackReceiptRemainsUncertain(rpc: Bool) async throws {
  let store = try neutralReceiptStore(service: .sms)
  var attempts = 0
  let sender = MessageSender(runner: { _, arguments in
    attempts += 1
    if attempts == 1 {
      throw DeliveryFailure(
        disposition: .notStarted, transport: .appleScript,
        operation: "send", detail: "synthetic first-attempt failure")
    }
    #expect(arguments[2] == "sms")
    try insertNeutralReceipt(store, id: 90, service: "iMessage", date: Date())
  })
  let resolve: SentMessageVerifier.Resolver = { store, options, chatID, sentAt in
    #expect(options.service == .sms)
    return try SentMessageVerifier.resolveSentMessageCandidate(
      store: store, options: options, chatID: chatID, since: sentAt.addingTimeInterval(-2))
  }
  if rpc {
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store, verbose: false, output: output,
      sendMessage: sender.sendResolvingRoute, resolveSentMessage: resolve)
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":1,"method":"send","params":{"to":"+123","text":"nonce","transport":"applescript"}}"#
    )
    #expect(output.responses.isEmpty)
    let error = try #require(output.errors.first?["error"] as? [String: Any])
    let data = try #require(error["data"] as? [String: Any])
    #expect(data["disposition"] as? String == "may_have_completed")
    #expect(data["retry_safe"] as? Bool == false)
  } else {
    let values = ParsedValues(
      positional: [], options: ["to": ["+123"], "text": ["nonce"]], flags: ["jsonOutput"])
    do {
      _ = try await StdoutCapture.capture {
        try await SendCommand.run(
          values: values, runtime: RuntimeOptions(parsedValues: values),
          sendMessage: sender.sendResolvingRoute, resolveSentMessage: resolve,
          storeFactory: { _ in store })
      }
      Issue.record("expected delivery uncertainty without an SMS receipt")
    } catch let failure as DeliveryFailure {
      #expect(failure.disposition == .mayHaveCompleted)
      #expect(!failure.retrySafe)
    }
  }
  #expect(attempts == 2)
}

private func neutralReceiptStore(service: MessageService) throws -> MessageStore {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  _ = try store.withConnection { db in
    try db.run(
      "UPDATE chat SET chat_identifier = '+123', guid = 'any;-;+123', service_name = ? WHERE ROWID = 1",
      service == .sms ? "iMessage" : "SMS")
  }
  return store
}

private func insertNeutralReceipt(
  _ store: MessageStore, id: Int64, service: String, date: Date
) throws {
  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service)
      VALUES (?, 1, 'nonce', ?, ?, 1, ?)
      """,
      id, "neutral-\(id)", CommandTestDatabase.appleEpoch(date), service)
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", id)
  }
}
