import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func audioAttachmentValues(audio: Bool) -> ParsedValues {
  ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "file": ["~/Desktop/recording.mp3"],
      "replyTo": ["parent-guid"],
    ],
    flags: audio ? ["audio"] : []
  )
}

@Test(arguments: [false, true])
func cliAudioAttachmentSelectsPreparerAndPreservesReply(audio: Bool) async throws {
  let values = audioAttachmentValues(audio: audio)
  var ordinaryPaths: [String] = []
  var audioPaths: [String] = []
  var bridgeParams: [String: Any] = [:]
  var appleScriptCalled = false

  _ = try await StdoutCapture.capture {
    try await SendAttachmentCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        #expect(action == .sendAttachment)
        bridgeParams = params
        return ["messageGuid": "synthetic-guid"]
      },
      stageAttachment: { path in
        ordinaryPaths.append(path)
        return "/tmp/staged-recording.mp3"
      },
      stageAudioAttachment: { path in
        audioPaths.append(path)
        return "/tmp/staged-voice.caf"
      },
      sendMessage: { _ in appleScriptCalled = true }
    )
  }

  let expectedInput = ("~/Desktop/recording.mp3" as NSString).expandingTildeInPath
  #expect(ordinaryPaths == (audio ? [] : [expectedInput]))
  #expect(audioPaths == (audio ? [expectedInput] : []))
  #expect(
    bridgeParams["filePath"] as? String
      == (audio ? "/tmp/staged-voice.caf" : "/tmp/staged-recording.mp3"))
  #expect(bridgeParams["isAudioMessage"] as? Bool == audio)
  #expect(bridgeParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(!appleScriptCalled)
}

@Test
func cliAudioPreparationFailureNeverDispatchesOrFallsBack() async {
  let values = audioAttachmentValues(audio: true)
  var bridgeCalled = false
  var appleScriptCalled = false
  var ordinaryCalled = false
  do {
    try await SendAttachmentCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        bridgeCalled = true
        return [:]
      },
      stageAttachment: { path in
        ordinaryCalled = true
        return path
      },
      stageAudioAttachment: { _ in
        throw IMsgError.appleScriptFailure("synthetic conversion failure")
      },
      sendMessage: { _ in appleScriptCalled = true }
    )
    Issue.record("expected audio conversion failure")
  } catch let error as IMsgError {
    #expect(error.localizedDescription.contains("synthetic conversion failure"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  #expect(!bridgeCalled)
  #expect(!appleScriptCalled)
  #expect(!ordinaryCalled)
}

@Test
func cliPreparedAudioNeverFallsBackAfterBridgeNotStarted() async {
  // No reply target: this isolates the audio-only fallback fence.
  let values = ParsedValues(
    positional: [],
    options: ["chat": ["iMessage;-;+15551234567"], "file": ["/tmp/voice.mp3"]],
    flags: ["audio"]
  )
  var appleScriptCalled = false
  do {
    _ = try await StdoutCapture.capture {
      try await SendAttachmentCommand.run(
        values: values,
        runtime: RuntimeOptions(parsedValues: values),
        invokeBridge: { action, _ in
          throw DeliveryFailure(
            disposition: .notStarted,
            transport: .bridgeV2,
            operation: action.rawValue,
            detail: "synthetic publication failure"
          )
        },
        stageAudioAttachment: { _ in "/tmp/staged-voice.caf" },
        sendMessage: { _ in appleScriptCalled = true }
      )
    }
    Issue.record("expected bridge failure")
  } catch is BridgeOutput.EmittedError {
    // The audio flag preserves the existing no-fallback policy.
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  #expect(!appleScriptCalled)
}

@Test(arguments: [false, true], ["audio", "is_audio", "as_voice"])
func rpcAudioAliasesUsePreparerInBothInitializers(lazy: Bool, alias: String) async throws {
  let databasePath = try CommandTestDatabase.makePath()
  let output = TestRPCOutput()
  var ordinaryCalled = false
  var preparedPaths: [String] = []
  var bridgeParams: [String: Any] = [:]
  let invoke: BridgeInvoker = { action, params in
    #expect(action == .sendAttachment)
    bridgeParams = params
    return ["messageGuid": "synthetic-guid"]
  }
  let ordinary: AttachmentStager = { path in
    ordinaryCalled = true
    return path
  }
  let audio: AttachmentStager = { path in
    preparedPaths.append(path)
    return "/tmp/staged-voice.caf"
  }
  let server: RPCServer
  if lazy {
    server = RPCServer(
      databasePath: databasePath, verbose: false, output: output,
      resolveSentMessage: { _, _, _, _ in nil }, invokeBridge: invoke,
      stageAttachment: ordinary, stageAudioAttachment: audio, isBridgeReady: { true }
    )
  } else {
    server = RPCServer(
      store: try MessageStore(path: databasePath), verbose: false, output: output,
      resolveSentMessage: { _, _, _, _ in nil }, invokeBridge: invoke,
      stageAttachment: ordinary, stageAudioAttachment: audio, isBridgeReady: { true }
    )
  }
  let request: [String: Any] = [
    "jsonrpc": "2.0", "id": "audio-routing", "method": "send.attachment",
    "params": [
      "chat_id": 1, "file": "~/Desktop/recording.mp3", alias: true,
      "reply_to": "parent-guid", "part_index": 2,
    ],
  ]
  await server.handleLineForTesting(
    String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))

  #expect(!ordinaryCalled)
  #expect(preparedPaths == [("~/Desktop/recording.mp3" as NSString).expandingTildeInPath])
  #expect(bridgeParams["filePath"] as? String == "/tmp/staged-voice.caf")
  #expect(bridgeParams["isAudioMessage"] as? Bool == true)
  #expect(bridgeParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(bridgeParams["partIndex"] as? Int == 2)
  #expect(output.errors.isEmpty)
  #expect(output.responses.count == 1)
}

@Test(arguments: [false, true])
func rpcAttachmentPreparationKeepsOrdinaryFilesAndStopsFailedAudio(audio: Bool) async throws {
  let output = TestRPCOutput()
  var ordinaryCalled = false
  var audioCalled = false
  var bridgeCalled = false
  var appleScriptCalled = false
  let server = RPCServer(
    store: try CommandTestDatabase.makeStoreForRPC(), verbose: false, output: output,
    sendMessage: { options in
      appleScriptCalled = true
      return options
    },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, params in
      bridgeCalled = true
      #expect(params["filePath"] as? String == "/tmp/unchanged.mp3")
      #expect(params["isAudioMessage"] as? Bool == false)
      return ["messageGuid": "synthetic-guid"]
    },
    stageAttachment: { _ in
      ordinaryCalled = true
      return "/tmp/unchanged.mp3"
    },
    stageAudioAttachment: { _ in
      audioCalled = true
      throw IMsgError.appleScriptFailure("synthetic conversion failure")
    }
  )
  let request: [String: Any] = [
    "jsonrpc": "2.0", "id": "preparation", "method": "send.attachment",
    "params": ["chat_id": 1, "file": "/tmp/source.mp3", "audio": audio],
  ]
  await server.handleLineForTesting(
    String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))
  #expect(ordinaryCalled == !audio)
  #expect(audioCalled == audio)
  #expect(bridgeCalled == !audio)
  #expect(!appleScriptCalled)
  #expect(output.errors.count == (audio ? 1 : 0))
  #expect(output.responses.count == (audio ? 0 : 1))
}
