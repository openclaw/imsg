import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcStatusAdvertisesBridgeMessageMethods() {
  let methods = Set(kSupportedRPCMethods)

  for method in [
    "send.rich",
    "send.attachment",
    "send.sticker",
    "poll.send",
    "messages.poll.send",
    "poll.vote",
    "messages.poll.vote",
    "tapback",
    "message.edit",
    "message.unsend",
    "message.delete",
    "message.notifyAnyways",
    "message.send_status",
  ] {
    #expect(methods.contains(method))
  }
}

@Test
func rpcPollVoteValidatesAndResolvesOption() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "vote-guid"]
    }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"vote","method":"poll.vote","params":{"chat_id":1,"#
    + #""poll_guid":"p:0/poll-guid-6","option_id":"choice-no","option_text":"spoofed","#
    + #""voter_handle":"spoofed"}}"#
  await server.handleLineForTesting(request)

  #expect(capturedAction == .sendPollVote)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["pollMessageGuid"] as? String == "poll-guid-6")
  #expect(capturedParams["optionIdentifier"] as? String == "choice-no")
  #expect(capturedParams["optionText"] as? String == "No")
  #expect(capturedParams["voterHandle"] == nil)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["event"] as? String == "imessage.poll.voted")
  #expect(result?["option_text"] as? String == "No")
  #expect(result?["message_id"] as? String == "vote-guid")
}

@Test
func rpcPollVoteRejectsOptionOutsidePoll() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"vote","method":"poll.vote","params":{"chat_id":1,"poll_guid":"poll-guid-6","option_id":"not-an-option"}}"#
  )

  let error = output.errors.first?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32602)
  #expect((error?["data"] as? String)?.contains("not an option") == true)
}

@Test
func rpcPollSendInvokesBridgeWithResolvedChat() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(action: BridgeAction, params: [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return [
        "messageGuid": "poll-guid",
        "poll": [
          "kind": "created",
          "event": "imessage.poll.created",
          "question": "Dinner?",
        ],
      ]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Dinner?","options":["Pizza","Sushi"],"#
      + #""reply_to":"parent-guid"}}"#
  )

  // First call sends the poll…
  #expect(calls.first?.action == .sendPoll)
  #expect(calls.first?.params["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(calls.first?.params["question"] as? String == "Dinner?")
  #expect(calls.first?.params["options"] as? [String] == ["Pizza", "Sushi"])
  #expect(calls.first?.params["selectedMessageGuid"] as? String == "parent-guid")
  // …then echoes the question as a plain caption so it is visible on the balloon.
  #expect(calls.count == 2)
  #expect(calls.last?.action == .sendMessage)
  #expect(calls.last?.params["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(calls.last?.params["message"] as? String == "Dinner?")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["event"] as? String == "imessage.poll.created")
  #expect(result?["guid"] as? String == "poll-guid")
  #expect((result?["poll"] as? [String: Any])?["kind"] as? String == "created")
}

@Test
func rpcPollSendUsesCommentOverrideWithoutPollGuid() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(action: BridgeAction, params: [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return [:]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Dinner?","comment":"Vote by 5pm","#
      + #""options":["Pizza","Sushi"]}}"#
  )

  #expect(calls.count == 2)
  #expect(calls.first?.action == .sendPoll)
  #expect(calls.first?.params["question"] as? String == "Dinner?")
  #expect(calls.last?.action == .sendMessage)
  #expect(calls.last?.params["message"] as? String == "Vote by 5pm")
}

@Test
func rpcNormalizesTapbackReactionAliases() throws {
  #expect(try normalizeBridgeReactionType("heart") == "love")
  #expect(try normalizeBridgeReactionType("thumbs-up") == "like")
  #expect(try normalizeBridgeReactionType("haha") == "laugh")
  #expect(try normalizeBridgeReactionType("question", remove: true) == "remove-question")
  #expect(try normalizeBridgeReactionType("remove-like") == "remove-like")
}

@Test
func rpcSendRichInvokesBridgeWithResolvedChat() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "rich-guid"]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"boom","effect":"confetti","reply_to":"parent-guid"}}"#
  )

  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["message"] as? String == "boom")
  #expect(capturedParams["effectId"] as? String == "com.apple.messages.effect.CKConfettiEffect")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["guid"] as? String == "rich-guid")
}

@Test
func rpcSendRichSuppressesQueuedBridgeGuid() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in
      ["messageGuid": "previous-guid", "queued": true]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"boom"}}"#
  )

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["queued"] as? Bool == true)
  #expect(result?["guid"] == nil)
  #expect(result?["message_id"] == nil)
}

@Test
func rpcSendRichResolvesQueuedBridgeGuidBeforeResponding() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    resolveSentMessage: { _, options, chatID, _ in
      #expect(options.text == "boom")
      #expect(chatID == 1)
      return Message(
        rowID: 42,
        chatID: 1,
        sender: "",
        text: "boom",
        date: Date(),
        isFromMe: true,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 0,
        guid: "actual-guid"
      )
    },
    invokeBridge: { _, _ in
      ["messageGuid": "previous-guid", "queued": true]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"boom"}}"#
  )

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["queued"] as? Bool == true)
  #expect(result?["guid"] as? String == "actual-guid")
  #expect(result?["message_id"] as? String == "actual-guid")
}

@Test
func rpcSendAttachmentStagesFileBeforeBridgeSend() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var stagedInput: String?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedParams = params
      return ["messageGuid": "attachment-guid"]
    },
    stageAttachment: { path in
      stagedInput = path
      return "/tmp/staged-file.png"
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"attachment","method":"send.attachment","params":{"#
    + #""chat_id":1,"file":"~/Desktop/file.png","audio":true,"reply_to":"parent-guid"}}"#
  await server.handleLineForTesting(line)

  #expect(stagedInput?.hasSuffix("/Desktop/file.png") == true)
  #expect(capturedParams["filePath"] as? String == "/tmp/staged-file.png")
  #expect(capturedParams["isAudioMessage"] as? Bool == true)
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["message_id"] as? String == "attachment-guid")
}

@Test
func rpcSendStickerStagesFileAndReturnsTransferGuid() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  var stagedInput: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "sticker-guid", "transferGuid": "transfer-guid"]
    },
    stageSticker: { path in
      stagedInput = path
      return PreparedStickerAsset(
        stagedPath: "/tmp/staged-sticker.png",
        sha256: String(repeating: "b", count: 64),
        pixelWidth: 300,
        pixelHeight: 300,
        uti: "public.png",
        byteCount: 100,
        accessibilityLabel: "Sticker label"
      )
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"sticker","method":"send.sticker","params":{"#
    + #""chat_id":1,"file":"~/Desktop/sticker.png","attach_to":"p:2/parent-guid","part_index":2}}"#
  await server.handleLineForTesting(line)

  #expect(capturedAction == .sendSticker)
  #expect(stagedInput?.hasSuffix("/Desktop/sticker.png") == true)
  #expect(capturedParams["filePath"] as? String == "/tmp/staged-sticker.png")
  #expect(capturedParams["contentHash"] as? String == String(repeating: "b", count: 64))
  #expect(capturedParams["pixelWidth"] as? Int == 300)
  #expect(capturedParams["pixelHeight"] as? Int == 300)
  #expect(capturedParams["accessibilityLabel"] as? String == "Sticker label")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["targetPartIndex"] as? Int == 2)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["message_id"] as? String == "sticker-guid")
  #expect(result?["transfer_guid"] as? String == "transfer-guid")
}

@Test
func rpcSendStickerPrefersIMessageForSharedIdentifierAndSendsStandalone() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget(
    includeSMSDuplicate: true)
  let output = TestRPCOutput()
  var capturedChatGUID: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedChatGUID = params["chatGuid"] as? String
      return ["transferGuid": "standalone-transfer"]
    },
    stageSticker: { _ in
      PreparedStickerAsset(
        stagedPath: "/tmp/staged-sticker.png",
        sha256: String(repeating: "d", count: 64),
        pixelWidth: 64,
        pixelHeight: 64,
        uti: "public.png",
        byteCount: 100,
        accessibilityLabel: "Sticker"
      )
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"standalone","method":"send.sticker","params":{"#
    + #""chat_identifier":"shared-target","file":"~/Desktop/sticker.png"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedChatGUID == "iMessage;+;chat123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transfer_guid"] as? String == "standalone-transfer")
}

@Test
func rpcSendStickerDistinguishesInvalidAssetsFromStagingFailures() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  for (assetError, expectedCode) in [
    (StickerAssetError.invalidFormat("unknown"), -32602),
    (StickerAssetError.couldNotStage("disk full"), -32603),
  ] {
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      stageSticker: { _ in throw assetError }
    )
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"asset-error","method":"send.sticker","params":{"chat_id":1,"file":"sticker.png"}}"#
    )
    let code = (output.errors.first?["error"] as? [String: Any])?["code"] as? Int
    #expect(code == expectedCode)
  }
}

@Test
func rpcSendStickerRejectsUnshippedAliasesAndMalformedRequests() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  let output = TestRPCOutput()
  var stageCalls = 0
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    },
    stageSticker: { _ in
      stageCalls += 1
      return PreparedStickerAsset(
        stagedPath: "/tmp/should-not-stage.png",
        sha256: String(repeating: "c", count: 64),
        pixelWidth: 64,
        pixelHeight: 64,
        uti: "public.png",
        byteCount: 100,
        accessibilityLabel: "Sticker"
      )
    }
  )
  let requests = [
    #"{"jsonrpc":"2.0","id":"alias","method":"attachments.sendSticker","params":{}}"#,
    #"{"jsonrpc":"2.0","id":"shape","method":"send.sticker","params":[]}"#,
    #"{"jsonrpc":"2.0","id":"unknown","method":"send.sticker","params":{"chat_id":1,"file":"x.png","partIndex":1}}"#,
    #"{"jsonrpc":"2.0","id":"chat-string","method":"send.sticker","params":{"chat_id":"1","file":"x.png"}}"#,
    #"{"jsonrpc":"2.0","id":"chat-float","method":"send.sticker","params":{"chat_id":1.0,"file":"x.png"}}"#,
    #"{"jsonrpc":"2.0","id":"chat-exponent","method":"send.sticker","params":{"chat_id":1e0,"file":"x.png"}}"#,
    #"{"jsonrpc":"2.0","id":"chat-conflict","method":"send.sticker","params":{"#
      + #""chat_id":1,"chat_guid":"iMessage;+;chat123","file":"x.png"}}"#,
    #"{"jsonrpc":"2.0","id":"bool","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":true}}"#,
    #"{"jsonrpc":"2.0","id":"float","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":1.5}}"#,
    #"{"jsonrpc":"2.0","id":"integral-float","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":0.0}}"#,
    #"{"jsonrpc":"2.0","id":"integral-exponent","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":0e0}}"#,
    #"{"jsonrpc":"2.0","id":"string","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":"1"}}"#,
    #"{"jsonrpc":"2.0","id":"orphan-part","method":"send.sticker","params":{"chat_id":1,"file":"x.png","part_index":1}}"#,
    #"{"jsonrpc":"2.0","id":"sms","method":"send.sticker","params":{"chat_guid":"SMS;-;+123","file":"x.png"}}"#,
    #"{"jsonrpc":"2.0","id":"wrong-chat","method":"send.sticker","params":{"chat_id":1,"file":"x.png","attach_to":"other-guid"}}"#,
  ]
  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(stageCalls == 0)
  #expect(bridgeCalls == 0)
  let codes = output.errors.compactMap {
    ($0["error"] as? [String: Any])?["code"] as? Int
  }
  #expect(codes.first == -32601)
  #expect(codes.dropFirst().allSatisfy { $0 == -32602 })
}

@Test
func rpcBridgeMessageMethodsResolveDirectChatIdentifierToGUID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedParams = params
      return [:]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"direct","method":"tapback","params":{"chat_identifier":"+123","message_id":"message-guid","reaction":"love"}}"#
  )

  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+123")
}
