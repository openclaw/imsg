import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func tapbackValues(kind: String, remove: Bool = false) -> ParsedValues {
  ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "message": ["parent-guid"],
      "kind": [kind],
      "part": ["1"],
    ],
    flags: remove ? ["remove"] : []
  )
}

@Test
func tapbackSendsCustomEmojiThroughCapableBridge() async throws {
  let values = tapbackValues(kind: "🎉", remove: true)
  var actions: [BridgeAction] = []
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await BridgeReactCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        actions.append(action)
        if action == .status {
          return ["selectors": ["emojiTapbackMessage": true] as [String: Any]]
        }
        capturedParams = params
        return ["messageGuid": "sent-guid"]
      }
    )
  }

  #expect(actions == [.status, .sendReaction])
  #expect(capturedParams["emoji"] as? String == "🎉")
  #expect(capturedParams["remove"] as? Bool == true)
  #expect(capturedParams["reactionType"] == nil)
  #expect(capturedParams["partIndex"] as? Int == 1)
  #expect(output.contains("tapback: 🎉 removed"))
}

@Test
func tapbackRejectsCustomEmojiBeforeSendOnBridgeWithoutSupport() async throws {
  let values = tapbackValues(kind: "🎉")
  var actions: [BridgeAction] = []

  await #expect(throws: IMsgError.self) {
    try await BridgeReactCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, _ in
        actions.append(action)
        return ["selectors": ["sendReaction": true] as [String: Any]]
      }
    )
  }
  #expect(actions == [.status])
}

@Test
func tapbackNormalizesClassicAliasesLikeRPC() async throws {
  for (kind, expected) in [("love", "love"), ("👍", "like"), ("heart", "remove-love")] {
    let values = tapbackValues(kind: kind, remove: kind == "heart")
    var actions: [BridgeAction] = []
    var capturedParams: [String: Any] = [:]

    _ = try await StdoutCapture.capture {
      try await BridgeReactCommand.run(
        values: values,
        runtime: RuntimeOptions(parsedValues: values),
        invokeBridge: { action, params in
          actions.append(action)
          capturedParams = params
          return [:]
        }
      )
    }

    #expect(actions == [.sendReaction])
    #expect(capturedParams["reactionType"] as? String == expected)
    #expect(capturedParams["emoji"] == nil)
  }
}

@Test
func tapbackRejectsUnknownKindBeforeInvokingBridge() async throws {
  let values = tapbackValues(kind: "banana")
  var bridgeCalls = 0

  await #expect(throws: IMsgError.self) {
    try await BridgeReactCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        bridgeCalls += 1
        return [:]
      }
    )
  }
  #expect(bridgeCalls == 0)
}
