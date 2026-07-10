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
