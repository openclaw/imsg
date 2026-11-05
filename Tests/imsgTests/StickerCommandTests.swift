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
func stickerCommandPlacesAttachedStickerOnlyThroughCapableBridge() async throws {
  let attached: [String: [String]] = [
    "chat": ["iMessage;-;+15551234567"], "file": ["sticker.png"], "attachTo": ["parent-guid"],
  ]
  let cases:
    [(
      name: String, options: [String: [String]], capable: Bool, placement: [String: Double]?,
      error: String?
    )] = [
      (
        "every value",
        attached.merging(["x": ["-0.25"], "y": ["1.2"], "scale": ["0.5"], "rotation": ["-90"]]) {
          $1
        },
        true, ["x": -0.25, "y": 1.2, "scale": 0.5, "rotation": -Double.pi / 2], nil
      ),
      (
        "defaults for the rest", attached.merging(["rotation": ["30"]]) { $1 }, true,
        ["x": 0.5, "y": 0.5, "scale": 1, "rotation": Double.pi / 6], nil
      ),
      (
        "bounds",
        attached.merging(["x": ["-3"], "y": ["3"], "scale": ["4"], "rotation": ["180"]]) { $1 },
        true, ["x": -3, "y": 3, "scale": 4, "rotation": Double.pi], nil
      ),
      (
        "older helper", attached.merging(["x": ["0.9"]]) { $1 }, false, nil,
        "running bridge does not support sticker placement"
      ),
      (
        "no target", ["chat": attached["chat"]!, "file": attached["file"]!, "x": ["0.9"]], true,
        nil,
        "require --attach-to / attach_to"
      ),
      (
        "out of range", attached.merging(["scale": ["5"]]) { $1 }, true, nil,
        "scale must be a number from 0.1 to 4"
      ),
      (
        "not a number", attached.merging(["y": ["nan"]]) { $1 }, true, nil,
        "Invalid value for option: --y"
      ),
    ]

  for testCase in cases {
    let values = ParsedValues(positional: [], options: testCase.options, flags: [])
    var actions: [BridgeAction] = []
    var sentPlacement: [String: Any]?
    var staged = false
    do {
      _ = try await StdoutCapture.capture {
        try await StickerCommand.run(
          values: values,
          runtime: RuntimeOptions(parsedValues: values),
          invokeBridge: { action, params in
            actions.append(action)
            if action == .status {
              return ["selectors": ["stickerPlacement": testCase.capable]]
            }
            sentPlacement = params["placement"] as? [String: Any]
            return ["messageGuid": "sent-guid", "transferGuid": "transfer-guid"]
          },
          resolveChat: { chat, _ in (chat, "iMessage") },
          messageBelongsToChat: { _, _, _ in true },
          prepareSticker: { _ in
            staged = true
            return PreparedStickerAsset(
              stagedPath: "/staged/sticker.png",
              sha256: String(repeating: "a", count: 64),
              pixelWidth: 64,
              pixelHeight: 64,
              uti: "public.png",
              byteCount: 100,
              accessibilityLabel: "Sticker"
            )
          }
        )
      }
      #expect(testCase.error == nil, "\(testCase.name): sent")
    } catch {
      #expect(
        testCase.error.map { String(describing: error).contains($0) } == true,
        "\(testCase.name): \(error)")
    }

    guard let expected = testCase.placement else {
      #expect(!actions.contains(.sendSticker) && !staged, "\(testCase.name): nothing sent")
      continue
    }
    #expect(actions == [.status, .sendSticker], "\(testCase.name)")
    for (key, value) in expected {
      let sent = sentPlacement?[key] as? Double
      #expect(sent.map { abs($0 - value) < 1e-12 } == true, "\(testCase.name): \(key)")
    }
    #expect(sentPlacement?.count == 4, "\(testCase.name)")
  }
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
