import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private struct SendVerificationTestError: Error {}

@Test
func rpcSendRichFileUsesAttachmentCapabilityAndSharedResponseEnrichment() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(BridgeAction, [String: Any])] = []
  var staged = ""
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, options, chatID, _ in
      #expect(options.text == "caption")
      #expect(chatID == 1)
      return Message(
        rowID: 88,
        chatID: 1,
        sender: "",
        text: "caption",
        date: Date(),
        isFromMe: true,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 1,
        guid: "resolved-attachment-guid"
      )
    },
    invokeBridge: { action, params in
      calls.append((action, params))
      if action == .status {
        return [
          "attachment_metadata": true,
          "selectors": ["sendAttachment": true] as [String: Any],
        ]
      }
      return ["chatGuid": "iMessage;+;chat123", "messageGuid": "bridge-guid"]
    },
    stageAttachment: {
      staged = $0
      return "/staged/photo.jpg"
    }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"rich-file","method":"send.rich","params":{"#
    + #""chat_id":1,"path":"~/photo.jpg","text":"caption","effect":"impact","#
    + #""subject":"Subject","reply_to":"parent-guid","part_index":2,"dd_scan":false,"#
    + #""text_formatting":[{"start":0,"length":7,"styles":["bold"]}]}}"#
  await server.handleLineForTesting(request)

  #expect(calls.map(\.0) == [.status, .sendAttachment])
  #expect(staged.hasSuffix("/photo.jpg"))
  let sent = try #require(calls.last?.1)
  #expect(sent["filePath"] as? String == "/staged/photo.jpg")
  #expect(sent["message"] as? String == "caption")
  #expect(sent["effectId"] as? String == "com.apple.MobileSMS.expressivesend.impact")
  #expect(sent["subject"] as? String == "Subject")
  #expect(sent["selectedMessageGuid"] as? String == "parent-guid")
  #expect(sent["partIndex"] as? Int == 2)
  #expect(sent["ddScan"] as? Bool == false)
  #expect((sent["textFormatting"] as? [[String: Any]])?.count == 1)
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect(result["ok"] as? Bool == true)
  #expect((result["id"] as? NSNumber)?.int64Value == 88)
  #expect(result["guid"] as? String == "resolved-attachment-guid")
  #expect(result["message_id"] as? String == "resolved-attachment-guid")
  #expect(result["chat_guid"] as? String == "iMessage;+;chat123")
}

@Test
func rpcSendRichFileWithoutCaptionVerifiesNewBridgeGUIDRow() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
  }
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, _, _, _ in
      Issue.record("empty-caption rich file should use canonical GUID verification")
      return nil
    },
    invokeBridge: { action, _ in
      actions.append(action)
      if action == .status {
        return ["selectors": ["sendAttachment": true] as [String: Any]]
      }
      try store.withConnection { db in
        try db.run(
          "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, guid) "
            + "VALUES (6, 1, '', ?, 1, 'iMessage', 'new-attachment-guid')",
          CommandTestDatabase.appleEpoch(Date())
        )
        try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
      }
      return ["messageGuid": "new-attachment-guid"]
    },
    stageAttachment: { _ in "/staged/photo.jpg" }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich-file","method":"send.rich","params":{"chat_id":1,"file":"photo.jpg"}}"#
  )

  #expect(actions == [.status, .sendAttachment])
  #expect(output.errors.isEmpty)
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect((result["id"] as? NSNumber)?.int64Value == 6)
  #expect(result["guid"] as? String == "new-attachment-guid")
  #expect(result["message_id"] as? String == "new-attachment-guid")
}

@Test
func rpcSendRichFileRejectsMissingAttachmentCapabilityBeforeStaging() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  var stageCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return ["selectors": ["sendAttachment": false] as [String: Any]]
    },
    stageAttachment: { _ in
      stageCalls += 1
      return "/must-not-stage"
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich-file","method":"send.rich","params":{"chat_id":1,"file":"photo.jpg"}}"#
  )

  #expect(actions == [.status])
  #expect(stageCalls == 0)
  #expect(output.responses.isEmpty)
  #expect((output.errors.first?["error"] as? [String: Any])?["code"] as? Int == -32603)
}

@Test
func rpcSendMultipartValidatesTextPartsAndNormalizesResponse() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var action: BridgeAction?
  var bridgeParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, options, chatID, _ in
      #expect(options.text == "hello world")
      #expect(chatID == 1)
      return Message(
        rowID: 99,
        chatID: 1,
        sender: "",
        text: options.text,
        date: Date(),
        isFromMe: true,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 0,
        guid: "multipart-resolved-guid"
      )
    },
    invokeBridge: { sentAction, params in
      action = sentAction
      bridgeParams = params
      return [
        "chatGuid": "iMessage;+;chat123",
        "messageGuid": "multipart-bridge-guid",
        "parts_count": 2,
      ]
    }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"multipart","method":"send.multipart","params":{"#
    + #""chat_id":1,"parts":[{"text":"hello ","text_formatting":[{"start":0,"#
    + #""length":5,"styles":["bold"]}]},{"text":"world"}],"effect":"confetti","#
    + #""subject":"Greeting"}}"#
  await server.handleLineForTesting(request)

  #expect(action == .sendMultipart)
  #expect(bridgeParams["effectId"] as? String == "com.apple.messages.effect.CKConfettiEffect")
  #expect(bridgeParams["subject"] as? String == "Greeting")
  let parts = try #require(bridgeParams["parts"] as? [[String: Any]])
  #expect(parts.map { $0["text"] as? String } == ["hello ", "world"])
  #expect((parts.first?["textFormatting"] as? [[String: Any]])?.count == 1)
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect(result["ok"] as? Bool == true)
  #expect((result["id"] as? NSNumber)?.int64Value == 99)
  #expect(result["guid"] as? String == "multipart-resolved-guid")
  #expect(result["message_id"] as? String == "multipart-resolved-guid")
  #expect(result["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(result["parts_count"] as? Int == 2)
}

@Test
func rpcSendMultipartRejectsUnobservedDeliveryWithoutRetry() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, _ in
      #expect(action == .sendMultipart)
      bridgeCalls += 1
      return ["messageGuid": "unobserved-guid"]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"multipart","method":"send.multipart","params":{"chat_id":1,"parts":[{"text":"unique nonce"}]}}"#
  )

  #expect(bridgeCalls == 1)
  #expect(output.responses.isEmpty)
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  let data = try #require(error["data"] as? [String: Any])
  #expect(error["code"] as? Int == -32001)
  #expect(data["disposition"] as? String == "may_have_completed")
  #expect(data["transport"] as? String == "bridge_v2")
  #expect(data["operation"] as? String == "send-multipart")
  #expect(data["retry_safe"] as? Bool == false)
}

@Test
func rpcSendRichFileMapsResolverErrorWithoutRetry() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, _, _, _ in throw SendVerificationTestError() },
    invokeBridge: { action, _ in
      actions.append(action)
      if action == .status {
        return [
          "attachment_metadata": true,
          "selectors": ["sendAttachment": true] as [String: Any],
        ]
      }
      return ["messageGuid": "unobserved-guid"]
    },
    stageAttachment: { _ in "/staged/photo.jpg" }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich-file","method":"send.rich","params":{"chat_id":1,"file":"photo.jpg","text":"unique caption"}}"#
  )

  #expect(actions == [.status, .sendAttachment])
  #expect(output.responses.isEmpty)
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  let data = try #require(error["data"] as? [String: Any])
  #expect(error["code"] as? Int == -32001)
  #expect(data["disposition"] as? String == "may_have_completed")
  #expect(data["transport"] as? String == "bridge_v2")
  #expect(data["operation"] as? String == "send-attachment")
}

@Test
func rpcSendMultipartRejectsSuccessWhenDatabaseUnavailable() async throws {
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    databasePath: "/unavailable/chat.db",
    verbose: false,
    output: output,
    storeFactory: { _ in throw SendVerificationTestError() },
    invokeBridge: { action, _ in
      #expect(action == .sendMultipart)
      bridgeCalls += 1
      return ["messageGuid": "unobserved-guid"]
    },
    isBridgeReady: { true }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"multipart","method":"send.multipart","params":{"#
    + #""chat_guid":"iMessage;+;chat123","parts":[{"text":"unique nonce"}]}}"#
  await server.handleLineForTesting(
    request
  )

  #expect(bridgeCalls == 1)
  #expect(output.responses.isEmpty)
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  let data = try #require(error["data"] as? [String: Any])
  #expect(error["code"] as? Int == -32001)
  #expect(data["disposition"] as? String == "may_have_completed")
  #expect(data["transport"] as? String == "bridge_v2")
  #expect(data["operation"] as? String == "send-multipart")
}

@Test
func rpcUnobservedSendNotificationRemainsSilent() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, _ in
      #expect(action == .sendMultipart)
      bridgeCalls += 1
      return ["messageGuid": "unobserved-guid"]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"send.multipart","params":{"chat_id":1,"parts":[{"text":"unique nonce"}]}}"#
  )

  #expect(bridgeCalls == 1)
  #expect(output.outputs.isEmpty)
}
