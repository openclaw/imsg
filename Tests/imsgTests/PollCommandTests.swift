import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func pollCommandSendInvokesPollBridge() async throws {
  let values = ParsedValues(
    positional: ["send"],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "question": ["Dinner?"],
      "replyTo": ["parent-guid"],
      "option": ["Pizza", "Sushi"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  let (output, _) = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return ["messageGuid": "poll-guid"]
      },
      // Stubbed: this test asserts bridge wiring, not row verification.
      verifyCaption: { _ in .delivered }
    )
  }

  // First call sends the poll…
  #expect(calls.first?.action == .sendPoll)
  #expect(calls.first?.params["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(calls.first?.params["question"] as? String == "Dinner?")
  #expect(calls.first?.params["options"] as? [String] == ["Pizza", "Sushi"])
  #expect(calls.first?.params["selectedMessageGuid"] as? String == "parent-guid")
  // …then echoes the question as a plain caption so it is visible on the balloon.
  #expect(calls.count == 2)
  #expect(calls.last?.action == .sendMessage)
  #expect(calls.last?.params["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(calls.last?.params["message"] as? String == "Dinner?")
  #expect(output.contains("poll: sent (guid=poll-guid)"))
}

@Test
func pollCommandSendUsesCommentOverrideWithoutPollGuid() async throws {
  let values = ParsedValues(
    positional: ["send"],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "question": ["Dinner?"],
      "comment": ["Vote by 5pm"],
      "option": ["Pizza", "Sushi"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  _ = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return [:]
      },
      // Stubbed: this test asserts bridge wiring, not row verification.
      verifyCaption: { _ in .delivered }
    )
  }

  #expect(calls.count == 2)
  #expect(calls.first?.action == .sendPoll)
  #expect(calls.first?.params["question"] as? String == "Dinner?")
  #expect(calls.last?.action == .sendMessage)
  #expect(calls.last?.params["message"] as? String == "Vote by 5pm")
}

@Test
func pollCommandSendCanSuppressCaption() async throws {
  let values = ParsedValues(
    positional: ["send"],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "question": ["Dinner?"],
      "option": ["Pizza", "Sushi"],
    ],
    flags: ["noComment"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  _ = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return ["messageGuid": "poll-guid"]
      }
    )
  }

  #expect(calls.count == 1)
  #expect(calls.first?.action == .sendPoll)
}

@Test
func pollCommandSendRejectsCommentWithNoComment() async throws {
  let values = ParsedValues(
    positional: ["send"],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "question": ["Dinner?"],
      "comment": ["Vote by 5pm"],
      "option": ["Pizza", "Sushi"],
    ],
    flags: ["noComment"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  do {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return [:]
      }
    )
    Issue.record("expected --comment with --no-comment to fail")
  } catch let error as ParsedValuesError {
    #expect(error.description == "Invalid value for option: --comment")
  }

  #expect(calls.isEmpty)
}

@Test
func pollCommandSendResolvesChatID() async throws {
  let values = ParsedValues(
    positional: ["send"],
    options: [
      "chatID": ["1"],
      "question": ["Dinner?"],
      "option": ["Pizza", "Sushi"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      invokeBridge: { _, params in
        capturedParams = params
        return ["messageGuid": "poll-guid"]
      },
      // Stubbed: this test asserts bridge wiring, not row verification.
      verifyCaption: { _ in .delivered }
    )
  }

  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
}

@Test
func pollCommandVoteResolvesOptionIndex() async throws {
  let values = ParsedValues(
    positional: ["vote"],
    options: [
      "chatID": ["1"],
      "poll": ["p:0/poll-guid-6"],
      "optionIndex": ["2"],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "vote-guid"]
      }
    )
  }

  #expect(capturedAction == .sendPollVote)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["pollMessageGuid"] as? String == "poll-guid-6")
  #expect(capturedParams["optionIdentifier"] as? String == "choice-no")
  #expect(capturedParams["optionText"] as? String == "No")
  let data = try #require(output.data(using: .utf8))
  let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(result["optionText"] as? String == "No")
}

@Test(arguments: [false, true])
func pollCommandUnvoteResolvesOptionText(updateReference: Bool) async throws {
  let values = ParsedValues(
    positional: ["unvote"],
    options: [
      "chatID": ["1"],
      "poll": ["p:0/poll-guid-6"],
      "option": ["Yes"],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPCWithOwnPollVoteSnapshot(
    updateReference: updateReference)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "unvote-guid"]
      }
    )
  }

  #expect(capturedAction == .sendPollUnvote)
  #expect(capturedParams["pollMessageGuid"] as? String == "poll-guid-6")
  #expect(capturedParams["optionIdentifier"] as? String == "choice-yes")
  #expect(capturedParams["optionText"] as? String == "Yes")
  #expect(capturedParams["remainingOptionIdentifiers"] as? [String] == ["choice-no"])
}

@Test
func pollCommandVoteRejectsConflictingSelectors() async throws {
  let values = ParsedValues(
    positional: ["vote"],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "poll": ["poll-guid-6"],
      "optionID": ["choice-yes"],
      "optionIndex": ["1"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  do {
    try await PollCommand.run(values: values, runtime: runtime)
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("choose exactly one"))
  }
}
