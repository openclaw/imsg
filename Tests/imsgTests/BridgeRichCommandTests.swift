import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func sendRichWithFileAndReplyUsesAttachmentBridge() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "text": ["here it is"],
      "file": ["~/Desktop/pic.jpg"],
      "replyTo": ["parent-guid"],
      "effect": ["impact"],
      "subject": ["subject"],
      "part": ["2"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  var stagedSource = ""

  let (output, _) = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "sent-guid"]
      },
      stageAttachment: { path in
        stagedSource = path
        return "/staged/pic.jpg"
      }
    )
  }

  #expect(capturedAction == .sendAttachment)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["message"] as? String == "here it is")
  #expect(capturedParams["filePath"] as? String == "/staged/pic.jpg")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["effectId"] as? String == "com.apple.MobileSMS.expressivesend.impact")
  #expect(capturedParams["subject"] as? String == "subject")
  #expect(capturedParams["partIndex"] as? Int == 2)
  #expect(capturedParams["isAudioMessage"] as? Bool == false)
  #expect(stagedSource.hasSuffix("/Desktop/pic.jpg"))
  #expect(output.contains("send-rich: sent (guid=sent-guid)"))
}

@Test
func sendRichTextOnlyStillUsesMessageBridge() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "text": ["hi"],
      "replyTo": ["parent-guid"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "sent-guid"]
      }
    )
  }

  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["message"] as? String == "hi")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["filePath"] == nil)
}

@Test
func sendRichJsonResolvesQueuedBridgeGuidBeforeEmitting() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;+;chat123"],
      "text": ["root card"],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()

  let (output, _) = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { _, _ in
        ["messageGuid": "stale-guid", "queued": true]
      },
      resolveSentMessage: { _, options, chatID, _ in
        #expect(options.text == "root card")
        #expect(chatID == 1)
        return Message(
          rowID: 42,
          chatID: 1,
          sender: "",
          text: "root card",
          date: Date(),
          isFromMe: true,
          service: "iMessage",
          handleID: nil,
          attachmentsCount: 0,
          guid: "actual-guid"
        )
      },
      storeFactory: { _ in store }
    )
  }

  let data = output.data(using: .utf8) ?? Data()
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["messageGuid"] as? String == "actual-guid")
  #expect(object["guid"] as? String == "actual-guid")
  #expect(object["message_id"] as? String == "actual-guid")
  #expect(object["id"] as? Int == 42)
}

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
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "poll-guid"]
      }
    )
  }

  #expect(capturedAction == .sendPoll)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["question"] as? String == "Dinner?")
  #expect(capturedParams["options"] as? [String] == ["Pizza", "Sushi"])
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(output.contains("poll: sent (guid=poll-guid)"))
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
      }
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
