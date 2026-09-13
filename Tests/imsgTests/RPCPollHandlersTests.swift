import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(arguments: [false, true])
func rpcPollUnvoteValidatesAndResolvesOption(updateReference: Bool) async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithOwnPollVoteSnapshot(
    updateReference: updateReference)
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
      return ["messageGuid": "unvote-guid"]
    }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"unvote","method":"polls.unvote","params":{"chat_id":1,"#
    + #""poll_guid":"p:0/poll-guid-6","option_id":"choice-yes"}}"#
  await server.handleLineForTesting(request)

  #expect(capturedAction == .sendPollUnvote)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["pollMessageGuid"] as? String == "poll-guid-6")
  #expect(capturedParams["optionIdentifier"] as? String == "choice-yes")
  #expect(capturedParams["optionText"] as? String == "Yes")
  #expect(capturedParams["remainingOptionIdentifiers"] as? [String] == ["choice-no"])
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["event"] as? String == "imessage.poll.unvoted")
  #expect(result?["option_text"] as? String == "Yes")
  #expect(result?["remaining_option_ids"] as? [String] == ["choice-no"])
  #expect(result?["message_id"] as? String == "unvote-guid")
}

@Test
func rpcPollUnvoteRejectsUnselectedOption() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unvote","method":"polls.unvote","params":{"chat_id":1,"poll_guid":"poll-guid-6","option_id":"choice-no"}}"#
  )

  let error = output.errors.first?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32602)
  #expect((error?["data"] as? String)?.contains("not currently selected") == true)
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
    + #""poll_guid":"p:0/poll-guid-6","option_id":"choice-no"}}"#
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
    },
    // Stubbed: this test asserts bridge wiring, not row verification.
    verifyCaption: { _, _, _ in .delivered }
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
    },
    // Stubbed: this test asserts bridge wiring, not row verification.
    verifyCaption: { _, _, _ in .delivered }
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
func rpcPollSendCanSuppressCaption() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(action: BridgeAction, params: [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return ["messageGuid": "poll-guid"]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Dinner?","options":["Pizza","Sushi"],"#
      + #""suppress_comment":true}}"#
  )

  #expect(calls.count == 1)
  #expect(calls.first?.action == .sendPoll)
}
