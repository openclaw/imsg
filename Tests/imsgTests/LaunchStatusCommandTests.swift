import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func commandRouterIncludesLaunchCommand() async {
  let router = CommandRouter()
  let names = router.specs.map(\.name)
  #expect(names.contains("launch"))
}

@Test
func commandRouterIncludesReadCommand() async {
  let router = CommandRouter()
  let names = router.specs.map(\.name)
  #expect(names.contains("read"))
}

@Test
func commandRouterIncludesStatusCommand() async {
  let router = CommandRouter()
  let names = router.specs.map(\.name)
  #expect(names.contains("status"))
}

@Test
func statusCommandProducesJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = await StdoutCapture.capture {
    try? await StatusCommand.run(values: values, runtime: runtime)
  }
  // JSON output should contain expected keys
  #expect(output.contains(#""version":"\#(IMsgVersion.current)""#))
  #expect(output.contains("basic_features"))
  #expect(output.contains("advanced_features"))
}

@Test
func statusCommandProducesTextOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = await StdoutCapture.capture {
    try? await StatusCommand.run(values: values, runtime: runtime)
  }
  #expect(output.contains("imsg Status Report"))
  #expect(output.contains(IMsgVersion.current))
}

@Test
func statusOnlyAdvertisesStickerSendWhenSelectorsAreReady() {
  #expect(!StatusCommand.availableBridgeSendCommands(selectors: [:]).contains("send-sticker"))
  #expect(
    !StatusCommand.availableBridgeSendCommands(selectors: ["stickerSend": false])
      .contains("send-sticker"))
  #expect(
    StatusCommand.availableBridgeSendCommands(selectors: ["stickerSend": true])
      .contains("send-sticker"))
}

@Test
func statusOnlyAdvertisesTrackedSendForCurrentHelperCapability() {
  #expect(!StatusCommand.advertisedRPCMethods(selectors: [:]).contains("send.tracked"))
  #expect(
    !StatusCommand.advertisedRPCMethods(selectors: ["clientMessageGuidReservation": false])
      .contains("send.tracked"))
  #expect(
    StatusCommand.advertisedRPCMethods(selectors: ["clientMessageGuidReservation": true])
      .contains("send.tracked"))
}

@Test(arguments: [false, true])
func statusPreservesSetupFailure(json: Bool) async throws {
  let values = ParsedValues(positional: [], options: [:], flags: json ? ["jsonOutput"] : [])
  let (output, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      availability: (false, "System Integrity Protection (SIP) is enabled."),
      probe: {
        Issue.record("An unavailable bridge must not be probed")
        return [:]
      })
  }
  #expect(!output.contains("not responding"))
  if json {
    let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    #expect(payload?["advanced_features"] as? Bool == false)
    #expect(payload?["message"] as? String == "System Integrity Protection (SIP) is enabled.")
    #expect(payload?["helper_version_mismatch"] == nil)
  } else {
    #expect(output.contains("Not available"))
  }
}

@Test(
  arguments: [
    IMsgBridgeError.timeout(action: "status"), .bridgeNotReady("launch failed"),
    .dylibReturnedError("unknown action"), .malformedResponse("invalid body"),
    .ioError("write failed"),
  ], [false, true])
func statusReportsProbeOutcome(error: IMsgBridgeError, json: Bool) async throws {
  let values = ParsedValues(positional: [], options: [:], flags: json ? ["jsonOutput"] : [])
  let timedOut = error == .timeout(action: "status")
  let (output, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      availability: (true, "Connected to Messages.app."), probe: { throw error })
  }
  if json {
    let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    #expect(payload?["helper_version_mismatch"] == nil)
    for key in ["advanced_features", "typing_indicators", "read_receipts"] {
      #expect(payload?[key] as? Bool == !timedOut)
    }
  }
  #expect(output.contains("not responding") == timedOut)
  if timedOut {
    #expect(output.contains("imsg launch"))
    #expect(!output.contains("Available - IMCore bridge connected"))
  }
}

@Test
func statusReportsHealthyBridgeCapabilities() async throws {
  let values = ParsedValues(positional: [], options: [:], flags: ["jsonOutput"])
  let (output, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      availability: (true, "Connected to Messages.app."),
      probe: { ["bridge_version": 2, "v2_ready": true, "selectors": ["stickerSend": true]] })
  }
  let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
  #expect(payload?["advanced_features"] as? Bool == true)
  #expect(payload?["bridge_version"] as? Int == 2)
  #expect(payload?["v2_ready"] as? Bool == true)
  #expect((payload?["selectors"] as? [String: Bool])?["stickerSend"] == true)
}

@Test(arguments: [nil, "older-release", IMsgVersion.current], [false, true])
func statusReportsHelperVersionMismatch(version: String?, json: Bool) async throws {
  let values = ParsedValues(positional: [], options: [:], flags: json ? ["jsonOutput"] : [])
  let (output, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      availability: (true, "Connected to Messages.app."),
      probe: {
        var result: [String: Any] = ["bridge_version": 2, "v2_ready": true]
        result["helper_version"] = version
        return result
      })
  }
  let mismatch = version != IMsgVersion.current
  if json {
    let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    #expect(payload?["helper_version"] as? String == version)
    #expect((payload?["helper_version_mismatch"] as? String != nil) == mismatch)
  } else {
    if let version {
      #expect(output.contains("helper dylib version: \(version)"))
    }
    #expect(output.contains("WARNING:") == mismatch)
  }
  #expect(output.contains("imsg launch") == mismatch)
}

@Test
func statusAdvertisesVersionedEmojiTapbackCapabilityOnlyWhenTheHelperSupportsIt() async throws {
  let values = ParsedValues(positional: [], options: [:], flags: ["jsonOutput"])
  let runtime = RuntimeOptions(parsedValues: values)

  let (withFeature, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: runtime,
      availability: (true, "Connected to Messages.app."),
      probe: {
        [
          "bridge_version": 2, "v2_ready": true, "registry_available": true,
          "selectors": ["emojiTapbackSend": true],
        ]
      })
  }
  #expect(withFeature.contains("\"capabilities\""))
  #expect(withFeature.contains("\"tapback.emoji\":2"))

  // The control: without the helper selector the capability is not advertised, so
  // a client keeps the six classic kinds.
  let (withoutFeature, _) = try await StdoutCapture.capture {
    try await StatusCommand.run(
      values: values, runtime: runtime,
      availability: (true, "Connected to Messages.app."),
      probe: {
        [
          "bridge_version": 2, "v2_ready": true, "registry_available": true,
          "selectors": ["emojiTapbackSend": false],
        ]
      })
  }
  #expect(withoutFeature.contains("\"capabilities\""))
  #expect(!withoutFeature.contains("tapback.emoji"))
}
