import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func stickerCommandStagesFileAndForwardsAttachTarget() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "file": ["~/Desktop/sticker.png"],
      "attachTo": ["p:3/parent-guid"],
      "targetPart": ["3"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  var stagedSource = ""

  let (output, _) = try await StdoutCapture.capture {
    try await StickerCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "sent-guid", "transferGuid": "transfer-guid"]
      },
      resolveChat: { chat, _ in (chat, "iMessage") },
      messageBelongsToChat: { messageGUID, chatGUID, _ in
        messageGUID == "parent-guid" && chatGUID == "iMessage;-;+15551234567"
      },
      prepareSticker: { path in
        stagedSource = path
        return PreparedStickerAsset(
          stagedPath: "/staged/sticker.png",
          sha256: String(repeating: "a", count: 64),
          pixelWidth: 300,
          pixelHeight: 240,
          uti: "public.png",
          byteCount: 123,
          accessibilityLabel: "Sticker label"
        )
      }
    )
  }

  #expect(capturedAction == .sendSticker)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["filePath"] as? String == "/staged/sticker.png")
  #expect(capturedParams["contentHash"] as? String == String(repeating: "a", count: 64))
  #expect(capturedParams["pixelWidth"] as? Int == 300)
  #expect(capturedParams["pixelHeight"] as? Int == 240)
  #expect(capturedParams["accessibilityLabel"] as? String == "Sticker label")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["targetPartIndex"] as? Int == 3)
  #expect(stagedSource.hasSuffix("/Desktop/sticker.png"))
  #expect(output.contains("sticker: sent (guid=sent-guid)"))
}

@Test
func stickerTargetNormalizesPartsAndRejectsConflicts() throws {
  #expect(
    try StickerSendTarget.resolve(rawTarget: "parent-guid", explicitPart: nil)
      == StickerSendTarget(messageGUID: "parent-guid", partIndex: 0)
  )
  #expect(
    try StickerSendTarget.resolve(rawTarget: "p:3/parent-guid", explicitPart: nil)
      == StickerSendTarget(messageGUID: "parent-guid", partIndex: 3)
  )
  #expect(
    try StickerSendTarget.resolve(rawTarget: "p:3/parent-guid", explicitPart: 3)
      == StickerSendTarget(messageGUID: "parent-guid", partIndex: 3)
  )
  #expect(throws: StickerSendValidationError.self) {
    try StickerSendTarget.resolve(rawTarget: "p:3/parent-guid", explicitPart: 2)
  }
  #expect(throws: StickerSendValidationError.self) {
    try StickerSendTarget.resolve(rawTarget: nil, explicitPart: 1)
  }
  #expect(throws: StickerSendValidationError.self) {
    try StickerSendTarget.resolve(rawTarget: "p:nope/parent-guid", explicitPart: nil)
  }
  #expect(throws: StickerSendValidationError.self) {
    try StickerSendTarget.resolve(rawTarget: "", explicitPart: nil)
  }
}

@Test
func stickerCommandAllowsNewDirectIMessageChat() async throws {
  let directGUID = "iMessage;-;+15559876543"
  let values = ParsedValues(
    positional: [],
    options: ["chat": [directGUID], "file": ["~/Desktop/sticker.png"]],
    flags: []
  )
  var capturedChatGUID: String?

  _ = try await StdoutCapture.capture {
    try await StickerCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, params in
        capturedChatGUID = params["chatGuid"] as? String
        return ["transferGuid": "transfer-guid"]
      },
      resolveChat: { _, _ in ("SMS;-;+15559876543", "SMS") },
      prepareSticker: { _ in
        PreparedStickerAsset(
          stagedPath: "/staged/sticker.png",
          sha256: String(repeating: "e", count: 64),
          pixelWidth: 64,
          pixelHeight: 64,
          uti: "public.png",
          byteCount: 100,
          accessibilityLabel: "Sticker"
        )
      }
    )
  }

  #expect(capturedChatGUID == directGUID)
  #expect(directStickerChatGUID("iMessageLite;-;person@example.com") != nil)
  #expect(directStickerChatGUID("SMS;-;+15559876543") == nil)
  #expect(directStickerChatGUID("iMessage;+;group-guid") == nil)
}
