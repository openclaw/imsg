import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcPollVoteResolvesOneBasedOptionIndex() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
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
    #"{"jsonrpc":"2.0","id":"vote","method":"poll.vote","params":{"chat_id":1,"poll_guid":"poll-guid-6","option_index":2}}"#
  )

  #expect(capturedParams["optionIdentifier"] as? String == "choice-no")
  #expect(capturedParams["optionText"] as? String == "No")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["option_id"] as? String == "choice-no")
  #expect(result?["option_text"] as? String == "No")
}

@Test
func rpcPollUnvoteAliasesResolveCaseInsensitiveOptionText() async throws {
  for method in ["poll.unvote", "polls.unvote", "messages.poll.unvote"] {
    let store = try CommandTestDatabase.makeStoreForRPCWithOwnPollVoteSnapshot()
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
        return [:]
      }
    )

    let request =
      #"{"jsonrpc":"2.0","id":"unvote","method":"\#(method)","params":{"chat_id":1,"poll_guid":"poll-guid-6","option":"yEs"}}"#
    await server.handleLineForTesting(request)

    #expect(capturedAction == .sendPollUnvote)
    #expect(capturedParams["optionIdentifier"] as? String == "choice-yes")
    #expect(capturedParams["optionText"] as? String == "Yes")
    #expect(capturedParams["remainingOptionIdentifiers"] as? [String] == ["choice-no"])
  }
}

@Test
func rpcPollVoteRejectsInvalidSelectors() async throws {
  let selectorCases: [(id: String, params: String, error: String)] = [
    ("missing", "", "one of option_id, option_index, or option is required"),
    (
      "multiple",
      #", "option_id":"choice-yes", "option_index":1"#,
      "choose exactly one of option_id, option_index, or option"
    ),
    ("out-of-range", #", "option_index":3"#, "out of range (1...2)"),
    ("unknown", #", "option":"Maybe""#, #"option "Maybe""#),
  ]

  for selectorCase in selectorCases {
    let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
    let output = TestRPCOutput()
    let server = RPCServer(store: store, verbose: false, output: output)
    let request =
      #"{"jsonrpc":"2.0","id":"\#(selectorCase.id)","method":"poll.vote","params":{"#
      + #""chat_id":1,"poll_guid":"poll-guid-6""#
      + selectorCase.params + "}}"

    await server.handleLineForTesting(request)

    let error = output.errors.first?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
    #expect((error?["data"] as? String)?.contains(selectorCase.error) == true)
  }
}

@Test
func rpcSendAttachmentValidatesReplyPartIndex() async throws {
  for params in [
    #""reply_to":"parent-guid","partIndex":true"#,
    #""reply_to":"parent-guid","part_index":-1"#,
    #""part_index":1"#,
  ] {
    let store = try CommandTestDatabase.makeStoreForRPC()
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      stageAttachment: { _ in "/tmp/staged-file.png" }
    )
    let request =
      #"{"jsonrpc":"2.0","id":"attachment","method":"send.attachment","params":{"chat_id":1,"file":"file.png",\#(params)}}"#

    await server.handleLineForTesting(request)

    let error = output.errors.first?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
  }
}
