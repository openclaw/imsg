import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private let preparedRichLinkFixture = PreparedRichLinkPreview(
  originalURL: "https://imsg.sh",
  resolvedURL: "https://imsg.sh/",
  title: "imsg",
  image: nil
)

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
func sendRichURLUsesPreparedMessageBridgePreviewDescriptor() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;+;chat123"],
      "url": ["https://imsg.sh"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  _ = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        if action == .status {
          return ["selectors": ["urlPreviewMessage": true, "sendRichLinkAction": true]]
        }
        return ["messageGuid": "sent-guid"]
      },
      storeFactory: { _ in store },
      prepareRichLink: { rawURL in
        #expect(rawURL == "https://imsg.sh")
        return preparedRichLinkFixture
      }
    )
  }

  #expect(calls.count == 2)
  #expect(calls.map(\.action) == [.status, .sendRichLink])
  #expect(calls.first?.params.isEmpty == true)
  let capturedParams = try #require(calls.last?.params)
  #expect(capturedParams["message"] as? String == "https://imsg.sh")
  #expect(capturedParams["ddScan"] as? Bool == true)
  let preview = try #require(capturedParams["richLinkPreview"] as? [String: Any])
  #expect(preview["version"] as? Int == 1)
  #expect(preview["originalURL"] as? String == "https://imsg.sh")
  #expect(preview["title"] as? String == "imsg")
}

@Test
func injectedHelperWiresURLPreviewBalloonSend() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = try String(contentsOf: helper, encoding: .utf8)

  #expect(source.contains("com.apple.messages.URLBalloonProvider"))
  #expect(source.contains("buildURLPreviewPayloadData"))
  #expect(source.contains("LPLinkMetadata"))
  #expect(source.contains("IMsgRichLinkArchiveProxy"))
  #expect(source.contains("urlPreviewMessage"))
  #expect(source.contains("sendRichLinkAction"))
  #expect(source.contains("params[@\"richLinkPreview\"]"))
  #expect(source.contains("if (richLinkPreview)"))
  #expect(source.contains("buildBalloonIMMessage(urlPreviewBalloonBundleIdentifier()"))
  #expect(source.contains("IMsgRichLinkImageAttachmentArchiveProxy"))
  #expect(source.contains("setClassName:@\"RichLink\""))
  #expect(source.contains("setClassName:@\"RichLinkImageAttachmentSubstitute\""))
  #expect(!source.contains("@interface RichLink :"))
  #expect(!source.contains("@interface RichLinkImageAttachmentSubstitute :"))
  #expect(!source.contains("LPMetadataProvider"))
  #expect(!source.contains("NSURLConnection"))
  #expect(source.contains("[metadata setValue:@[substitute] forKey:@\"contentImages\"]"))
  #expect(source.contains("prepareUnregisteredOutgoingTransfer(previewFile"))
  #expect(source.contains("fileTransferGuids.count > 0"))
  #expect(source.contains("fileTransferGuids"))
  #expect(source.contains("\"__kIMLinkIsRichLinkAttributeName\""))
  #expect(!source.contains("IMDDController"))
  #expect(!source.contains("scanOutgoingMessageForDataDetectors(imMessage)"))
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
func sendRichURLResolvesQueuedBridgeGuidWithURL() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;+;chat123"],
      "url": ["https://imsg.sh"],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  let (output, _) = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        if action == .status {
          return ["selectors": ["urlPreviewMessage": true, "sendRichLinkAction": true]]
        }
        return ["messageGuid": "stale-guid", "queued": true]
      },
      resolveSentMessage: { _, options, chatID, _ in
        #expect(options.text == "https://imsg.sh")
        #expect(chatID == 1)
        return Message(
          rowID: 42,
          chatID: 1,
          sender: "",
          text: "https://imsg.sh",
          date: Date(),
          isFromMe: true,
          service: "iMessage",
          handleID: nil,
          attachmentsCount: 0,
          guid: "actual-rich-link-guid"
        )
      },
      storeFactory: { _ in store },
      prepareRichLink: { _ in preparedRichLinkFixture }
    )
  }

  #expect(calls.map(\.action) == [.status, .sendRichLink])
  let data = output.data(using: .utf8) ?? Data()
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["messageGuid"] as? String == "actual-rich-link-guid")
  #expect(object["guid"] as? String == "actual-rich-link-guid")
  #expect(object["message_id"] as? String == "actual-rich-link-guid")
}

@Test
func sendRichURLRejectsStaleHelperBeforePreparationOrSend() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;+;chat123"],
      "url": ["https://imsg.sh"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  var calls: [(action: BridgeAction, params: [String: Any])] = []
  var prepared = false

  do {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return ["selectors": ["urlPreviewMessage": true]]
      },
      storeFactory: { _ in store },
      prepareRichLink: { _ in
        prepared = true
        return preparedRichLinkFixture
      }
    )
    Issue.record("expected an outdated helper to reject rich-link sends")
  } catch let error as RichLinkPreparationError {
    #expect(error == .unsupportedBridge)
  } catch {
    Issue.record("unexpected error: \(error)")
  }

  #expect(calls.count == 1)
  #expect(calls.first?.action == .status)
  #expect(calls.first?.params.isEmpty == true)
  #expect(!prepared)
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
  var calls: [(action: BridgeAction, params: [String: Any])] = []

  let (output, _) = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        calls.append((action, params))
        return ["messageGuid": "poll-guid"]
      }
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
      }
    )
  }

  #expect(calls.count == 2)
  #expect(calls.first?.action == .sendPoll)
  #expect(calls.first?.params["question"] as? String == "Dinner?")
  #expect(calls.last?.action == .sendMessage)
  #expect(calls.last?.params["message"] as? String == "Vote by 5pm")
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
func pollCommandUnvoteResolvesOptionText() async throws {
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
  let store = try CommandTestDatabase.makeStoreForRPCWithOwnPollVoteSnapshot()
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
