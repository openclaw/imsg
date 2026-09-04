import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcSendFallsBackOnlyWhenBridgeProvesNotStarted() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture,
    invokeBridge: { action, _ in
      throw DeliveryFailure(
        disposition: .notStarted,
        transport: .bridgeV2,
        operation: action.rawValue,
        detail: "request publication failed"
      )
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"safe-fallback","method":"send","params":{"to":"+123","text":"yo"}}"#
  )

  #expect(captured?.recipient == "+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "applescript")
}

@Test
func rpcExplicitBridgeReportsStructuredRetrySafeFailure() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      throw DeliveryFailure(
        disposition: .notStarted,
        transport: .bridgeV2,
        operation: action.rawValue,
        detail: "request publication failed"
      )
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"explicit-safe","method":"send","params":{"to":"+123","text":"yo","transport":"bridge"}}"#
  )

  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(error?["code"] as? Int == -32603)
  #expect(data?["retry_safe"] as? Bool == true)
  #expect(data?["disposition"] as? String == "not_started")
  #expect(data?["transport"] as? String == "bridge_v2")
  #expect(data?["operation"] as? String == "send-message")
}

@Test
func rpcSendFallsBackWhenBridgeIsNotReady() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
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
    resolveSentMessage: resolvedSentMessageFixture,
    invokeBridge: { _, _ in
      bridgeCalled = true
      return [:]
    },
    isBridgeReady: { false }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"not-ready","method":"send","params":{"to":"+123","text":"yo"}}"#
  )

  #expect(!bridgeCalled)
  #expect(appleScriptCalled)
}
