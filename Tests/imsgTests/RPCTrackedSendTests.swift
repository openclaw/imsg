import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private let trackedAttemptID = "8cc0c53a-7844-45ef-8b90-11f8a3e2cb66"

private func trackedRequest(id: String, attemptID: String = trackedAttemptID) -> String {
  """
  {"jsonrpc":"2.0","id":"\(id)","method":"send.tracked",
  "params":{"to":"+123","text":"once","attempt_id":"\(attemptID)"}}
  """
}

@Test
func rpcTrackedSendForwardsCallerOwnedGuidAndReturnsExactIdentity() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedActions: [BridgeAction] = []
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      appleScriptCalled = true
      return options
    },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, params in
      capturedActions.append(action)
      if action == .status {
        return ["selectors": ["clientMessageGuidReservation": true]]
      }
      capturedParams = params
      return [
        "messageGuid": trackedAttemptID,
        "chatGuid": "iMessage;-;+123",
        "service": "iMessage",
      ]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    trackedRequest(id: "tracked", attemptID: trackedAttemptID.uppercased()))

  #expect(appleScriptCalled == false)
  #expect(capturedActions == [.status, .sendMessage])
  #expect(capturedParams["clientMessageGuid"] as? String == trackedAttemptID)
  #expect(capturedParams["message"] as? String == "once")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["attempt_id"] as? String == trackedAttemptID)
  #expect(result?["guid"] as? String == trackedAttemptID)
  #expect(result?["message_id"] as? String == trackedAttemptID)
}

@Test
func rpcTrackedSendRejectsBeforeDispatchWithoutCurrentHelperCapability() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedActions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      appleScriptCalled = true
      return options
    },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, _ in
      capturedActions.append(action)
      return ["selectors": ["clientMessageGuid": true]]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(trackedRequest(id: "tracked-stale"))

  #expect(appleScriptCalled == false)
  #expect(capturedActions == [.status])
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(data?["disposition"] as? String == "not_started")
  #expect(data?["retry_safe"] as? Bool == true)
}

@Test
func rpcTrackedSendRejectsExistingGuidCaseInsensitivelyBeforeBridgeIO() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("UPDATE message SET guid = ? WHERE ROWID = 5", trackedAttemptID.uppercased())
  }
  let output = TestRPCOutput()
  var bridgeCalled = false
  var appleScriptCalled = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      appleScriptCalled = true
      return options
    },
    invokeBridge: { _, _ in
      bridgeCalled = true
      return [:]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(trackedRequest(id: "tracked-collision"))

  #expect(bridgeCalled == false)
  #expect(appleScriptCalled == false)
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(data?["disposition"] as? String == "not_started")
  #expect(data?["retry_safe"] as? Bool == true)
}

@Test
func rpcTrackedSendNeverFallsBackAfterUncertainBridgeDispatch() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      appleScriptCalled = true
      return options
    },
    invokeBridge: { action, _ in
      actions.append(action)
      if action == .status {
        return ["selectors": ["clientMessageGuidReservation": true]]
      }
      throw DeliveryFailure(
        disposition: .mayHaveCompleted,
        transport: .bridgeV2,
        operation: action.rawValue,
        detail: "fault injection after publication"
      )
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(trackedRequest(id: "tracked-uncertain"))

  #expect(actions == [.status, .sendMessage])
  #expect(appleScriptCalled == false)
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(data?["disposition"] as? String == "may_have_completed")
  #expect(data?["retry_safe"] as? Bool == false)
}

@Test
func rpcTrackedSendRejectsInvalidAttemptIdWithoutBridgeIO() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var bridgeCalled = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalled = true
      return [:]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    trackedRequest(id: "tracked-invalid", attemptID: "not-a-uuid"))

  #expect(bridgeCalled == false)
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32602)
}
