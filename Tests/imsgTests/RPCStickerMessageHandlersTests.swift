import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

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
func rpcSendStickerAllowsNewDirectIMessageChatGUID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  let output = TestRPCOutput()
  let directGUID = "iMessage;-;+15559876543"
  var capturedChatGUID: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedChatGUID = params["chatGuid"] as? String
      return ["transferGuid": "direct-transfer"]
    },
    stageSticker: { _ in
      PreparedStickerAsset(
        stagedPath: "/tmp/staged-sticker.png",
        sha256: String(repeating: "f", count: 64),
        pixelWidth: 64,
        pixelHeight: 64,
        uti: "public.png",
        byteCount: 100,
        accessibilityLabel: "Sticker"
      )
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"direct","method":"send.sticker","params":{"chat_guid":"iMessage;-;+15559876543","file":"sticker.png"}}"#
  )

  #expect(capturedChatGUID == directGUID)
  #expect(output.errors.isEmpty)
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
