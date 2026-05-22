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
