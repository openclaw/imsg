import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcICloudStatusReadsSyncStateWithoutStartingSync() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return ["syncing": false, "last_sync_at": "2026-11-03T16:17:23Z"]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"icloud","method":"icloud.status"}"#)

  #expect(actions == [.getICloudSyncStatus])
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect(result["ok"] as? Bool == true)
  #expect(result["syncing"] as? Bool == false)
  #expect(result["last_sync_at"] as? String == "2026-11-03T16:17:23Z")
  #expect(result["requested"] == nil)
}

@Test
func rpcICloudSyncStartsSyncAndReportsUnknownLastSyncAsNull() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return ["requested": true, "syncing": true, "last_sync_at": NSNull()]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"icloud","method":"icloud.sync","params":{}}"#)

  #expect(actions == [.startICloudSync])
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect(result["ok"] as? Bool == true)
  #expect(result["requested"] as? Bool == true)
  #expect(result["syncing"] as? Bool == true)
  #expect(result["last_sync_at"] is NSNull)
}

@Test
func rpcICloudMethodsRejectParamsBeforeBridgeDispatch() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status","method":"icloud.status","params":{"force":true}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"sync","method":"icloud.sync","params":[true]}"#)

  #expect(bridgeCalls == 0)
  #expect(output.errors.count == 2)
  for response in output.errors {
    let error = response["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
  }
}

@Test
func rpcICloudMethodsRequireReadyBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    },
    isBridgeReady: { false }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status","method":"icloud.status"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"sync","method":"icloud.sync"}"#)

  #expect(bridgeCalls == 0)
  let statusError = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(statusError["code"] as? Int == -32003)
  let syncError = try #require(output.errors.last?["error"] as? [String: Any])
  let syncData = try #require(syncError["data"] as? [String: Any])
  #expect(syncData["disposition"] as? String == "not_started")
  #expect(syncData["retry_safe"] as? Bool == true)
  #expect(syncData["operation"] as? String == "start-icloud-sync")
}

@Test
func rpcAdvertisesICloudMethodsFromHelperSelectors() async throws {
  #expect(rpcRequestLane(for: "icloud.status") == .read)
  #expect(rpcRequestLane(for: "icloud.sync") == .mutation)
  #expect(kSupportedRPCMethods.contains("icloud.status"))
  #expect(kSupportedRPCMethods.contains("icloud.sync"))

  let store = try CommandTestDatabase.makeStoreForRPC()
  for (status, sync) in [(false, false), (true, false), (true, true)] {
    var selectors = fullRPCStatusBridgeSelectors()
    selectors["icloudSyncStatus"] = status
    selectors["icloudSync"] = sync
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        // The CloudKit hooks do not depend on the chat registry.
        action == .status
          ? rpcStatusBridgeSnapshot(selectors: selectors, registryAvailable: false) : [:]
      },
      isBridgeReady: { true }
    )
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
    let methods = rpcStatusMethods(try rpcStatusResult(output))
    #expect(methods.contains("icloud.status") == status)
    #expect(methods.contains("icloud.sync") == sync)
  }
}

@Test
func icloudCommandInvokesMatchingBridgeActions() async throws {
  let cases: [(argument: String, action: BridgeAction, summary: String)] = [
    ("status", .getICloudSyncStatus, "icloud: syncing=false last_sync_at=never"),
    ("sync", .startICloudSync, "icloud: sync requested syncing=false last_sync_at=never"),
  ]
  for testCase in cases {
    let values = ParsedValues(positional: [testCase.argument], options: [:], flags: [])
    var capturedAction: BridgeAction?
    var capturedParams: [String: Any] = ["unexpected": true]
    let (output, _) = try await StdoutCapture.capture {
      try await ICloudCommand.run(
        values: values,
        runtime: RuntimeOptions(parsedValues: values),
        invokeBridge: { action, params in
          capturedAction = action
          capturedParams = params
          return ["syncing": false, "last_sync_at": NSNull()]
        }
      )
    }
    #expect(capturedAction == testCase.action)
    #expect(capturedParams.isEmpty)
    #expect(output.contains(testCase.summary))
  }
}

@Test
func icloudCommandEmitsBridgePayloadAsJSON() async throws {
  let values = ParsedValues(positional: ["sync"], options: [:], flags: ["jsonOutput"])
  let (output, _) = try await StdoutCapture.capture {
    try await ICloudCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        ["requested": true, "syncing": true, "last_sync_at": "2026-11-03T16:17:23Z"]
      }
    )
  }
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  #expect(payload["requested"] as? Bool == true)
  #expect(payload["syncing"] as? Bool == true)
  #expect(payload["last_sync_at"] as? String == "2026-11-03T16:17:23Z")
}

@Test
func icloudCommandRejectsUnknownAction() async {
  let values = ParsedValues(positional: ["force"], options: [:], flags: [])
  var bridgeInvoked = false
  do {
    try await ICloudCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        bridgeInvoked = true
        return [:]
      }
    )
    Issue.record("expected icloud to reject an unknown action")
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("action"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  #expect(!bridgeInvoked)
}

@Test
func injectedHelperGuardsICloudSyncSelectors() throws {
  let source = stripObjectiveCComments(try injectedHelperSource())
  let dispatchBody = try #require(bridgeFunctionBody(named: "dispatchAction", in: source))
  let statusBody = try #require(bridgeFunctionBody(named: "handleStatus", in: source))
  let probeBody = try #require(bridgeFunctionBody(named: "icloudSyncSelectorStatus", in: source))
  let startBody = try #require(bridgeFunctionBody(named: "handleStartICloudSync", in: source))
  let readBody = try #require(bridgeFunctionBody(named: "handleGetICloudSyncStatus", in: source))

  #expect(dispatchBody.contains(#"[action isEqualToString:@"get-icloud-sync-status"]"#))
  #expect(dispatchBody.contains(#"[action isEqualToString:@"start-icloud-sync"]"#))
  #expect(statusBody.contains(#"@"icloudSyncStatus": icloudSelectors[@"status"]"#))
  #expect(statusBody.contains(#"@"icloudSync": icloudSelectors[@"sync"]"#))
  #expect(probeBody.contains(#"NSClassFromString(@"IMCloudKitHooks")"#))
  #expect(probeBody.contains("kICloudStartSyncSelector"))
  #expect(source.contains(#"kICloudStartSyncSelector = @"startUserInitiatedSync""#))
  #expect(source.contains(#"kICloudIsSyncingSelector = @"isSyncing""#))
  #expect(source.contains(#"kICloudLastSyncDateSelector = @"lastSyncDate""#))

  // A missing selector refuses before calling into CloudKit, so the RPC
  // mutation reports a retry-safe not_started failure.
  let refusal = try #require(startBody.range(of: #"@"not_started""#))
  let start = try #require(startBody.range(of: "NSSelectorFromString(kICloudStartSyncSelector)"))
  #expect(refusal.lowerBound < start.lowerBound)
  #expect(!readBody.contains("kICloudStartSyncSelector"))
}
