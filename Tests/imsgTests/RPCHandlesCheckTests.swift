import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func handlesCheckInt64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcHandlesCheckInvokesBridgeAndReturnsAvailability() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
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
      return [
        "address": "+14159369340",
        "alias_type": "phone",
        "destination": "tel:+14159369340",
        "id_status": 3,
        "available": true,
      ]
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"Phone","service":"iMessage"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedAction == .checkImessageAvailability)
  #expect(capturedParams["address"] as? String == "+14159369340")
  #expect(capturedParams["aliasType"] as? String == "phone")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["address"] as? String == "+14159369340")
  #expect(result?["alias_type"] as? String == "phone")
  #expect(result?["destination"] as? String == "tel:+14159369340")
  #expect(handlesCheckInt64Value(result?["id_status"]) == 3)
  #expect(result?["available"] as? Bool == true)
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcHandlesCheckRequiresAddress() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsInvalidAliasType() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"url"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsSmsService() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","service":"sms"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRequiresReadyBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeInvoked = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeInvoked = true
      return [:]
    },
    isBridgeReady: { false }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340"}}"#
  await server.handleLineForTesting(line)

  #expect(bridgeInvoked == false)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32003)
}
