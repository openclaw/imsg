import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcGroupSetIconStagesFileBeforeBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var staged: [String] = []
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
    },
    stageAttachment: { path in
      staged.append(path)
      return "/tmp/staged-icon.jpg"
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"icon","method":"group.setIcon","params":{"chat_id":1,"file":"~/Pictures/icon.jpg"}}"#
  )

  #expect(capturedAction == .updateGroupPhoto)
  #expect(staged == [("~/Pictures/icon.jpg" as NSString).expandingTildeInPath])
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["filePath"] as? String == "/tmp/staged-icon.jpg")
  #expect((output.responses.first?["result"] as? [String: Any])?["ok"] as? Bool == true)
}

@Test
func rpcGroupSetIconClearSkipsStaging() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var staged = false
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedParams = params
      return [:]
    },
    stageAttachment: { _ in
      staged = true
      return "/tmp/staged-icon.jpg"
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"clear","method":"group.setIcon","params":{"chat_guid":"iMessage;+;chat123"}}"#
  )

  #expect(staged == false)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(capturedParams["filePath"] == nil)
  #expect((output.responses.first?["result"] as? [String: Any])?["ok"] as? Bool == true)
}
