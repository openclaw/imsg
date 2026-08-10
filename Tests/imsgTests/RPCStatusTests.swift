import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private final class RetryStoreFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let store: MessageStore
  private var failuresRemaining: Int
  private(set) var calls = 0

  init(store: MessageStore, failures: Int) {
    self.store = store
    self.failuresRemaining = failures
  }

  func open(_ path: String) throws -> MessageStore {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw NSError(domain: "RPCStatusTests", code: 1)
    }
    return store
  }
}

@Test
func rpcStatusWorksWithDatabaseAndBridgeDown() async throws {
  let output = TestRPCOutput()
  let invocations = RPCStatusInvocationCounter()
  let server = makeUnavailableRPCStatusServer(
    output: output,
    invokeBridge: { _, _ in
      invocations.increment()
      return [:]
    })

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status","method":"status","params":{}}"#)

  let result = try rpcStatusResult(output)
  #expect(result["version"] as? String == IMsgVersion.current)
  #expect(result["protocol_version"] as? Int == 1)
  let database = try #require(result["database"] as? [String: Any])
  #expect(database["ready"] as? Bool == false)
  #expect((database["error"] as? String)?.contains("does not exist") == true)
  let bridge = try #require(result["bridge"] as? [String: Any])
  #expect(bridge["ready"] as? Bool == false)
  #expect(invocations.value == 0)
  let methods = rpcStatusMethods(result)
  #expect(methods.isSuperset(of: ["initialize", "status", "watch.unsubscribe", "send"]))
  #expect(!methods.contains("chats.list"))
  #expect(!methods.contains("group.rename"))
}

@Test
func rpcInitializeNegotiatesVersionStrictlyAndIsIdempotent() async throws {
  let output = TestRPCOutput()
  let server = makeUnavailableRPCStatusServer(output: output)

  for id in ["one", "two"] {
    await server.handleLineForTesting(
      """
      {"jsonrpc":"2.0","id":"\(id)","method":"initialize","params":{"protocol_version":1}}
      """)
  }
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unsupported","method":"initialize","params":{"protocol_version":2}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unknown","method":"initialize","params":{"extra":true}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status-extra","method":"status","params":{"extra":true}}"#)

  #expect(output.responses.count == 2)
  #expect(output.errors.count == 3)
  for response in output.responses {
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["protocol_version"] as? Int == 1)
  }
  for envelope in output.errors {
    let error = try #require(envelope["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32602)
  }
}

@Test
func rpcDatabaseRecoversInSameServerAndCachesSuccess() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let factory = RetryStoreFactory(store: store, failures: 1)
  let output = TestRPCOutput()
  let server = RPCServer(
    databasePath: "/tmp/recovering-chat.db",
    verbose: false,
    output: output,
    storeFactory: factory.open,
    isBridgeReady: { false }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"down","method":"status"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"up","method":"status"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"chats","method":"chats.list","params":{"limit":1}}"#)

  let down = try rpcStatusResult(output, at: 0)
  let up = try rpcStatusResult(output, at: 1)
  #expect((down["database"] as? [String: Any])?["ready"] as? Bool == false)
  #expect((up["database"] as? [String: Any])?["ready"] as? Bool == true)
  #expect(rpcStatusMethods(up).contains("chats.list"))
  let chats = try rpcStatusResult(output, at: 2)["chats"] as? [[String: Any]]
  #expect(chats?.count == 1)
  #expect(factory.calls == 2)
}

@Test(.timeLimit(.minutes(1)))
func rpcFileBackedDatabaseRemainsUsableAfterStatusAcrossRuntimeLanes() async throws {
  let path = try CommandTestDatabase.makePath()
  let output = TestRPCOutput()
  let server = RPCServer(
    databasePath: path,
    verbose: false,
    output: output,
    isBridgeReady: { false }
  )
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(#"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
  await output.waitForOutputCount(1)
  let status = try rpcStatusResult(output)
  #expect((status["database"] as? [String: Any])?["ready"] as? Bool == true)

  input.yield(
    #"{"jsonrpc":"2.0","id":"chats","method":"chats.list","params":{"limit":1}}"#)
  await output.waitForOutputCount(2)
  input.finish()
  try await run.value

  let chats = try rpcStatusResult(output, at: 1)["chats"] as? [[String: Any]]
  #expect(chats?.count == 1)
  #expect(output.errors.isEmpty)
}

@Test
func rpcDatabaseUnavailableIsTypedWhileDirectSendStillWorks() async throws {
  let output = TestRPCOutput()
  var sent: MessageSendOptions?
  let server = makeUnavailableRPCStatusServer(
    output: output,
    sendMessage: { sent = $0 }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"db","method":"chats.list"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"send","method":"send","params":{"to":"+123","text":"hello"}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"chat-id","method":"send","params":{"chat_id":1,"text":"hello"}}"#)

  let databaseError = try #require(output.errors[0]["error"] as? [String: Any])
  #expect(databaseError["code"] as? Int == -32002)
  #expect(databaseError["message"] as? String == "Database unavailable")
  #expect(sent?.recipient == "+123")
  let sendResult = try rpcStatusResult(output)
  #expect(sendResult["transport"] as? String == "applescript")
  #expect(sendResult["id"] == nil)
  #expect(output.errors.count == 2)
  #expect((output.errors[1]["error"] as? [String: Any])?["code"] as? Int == -32002)
}

@Test
func rpcExplicitGUIDBridgeTargetBypassesDatabaseButValidatedMethodsDoNot() async throws {
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = makeUnavailableRPCStatusServer(
    output: output,
    bridgeReady: true,
    invokeBridge: { action, _ in
      actions.append(action)
      return action == .status ? rpcStatusBridgeSnapshot() : [:]
    })

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rename","method":"group.rename","params":{"chat_guid":"iMessage;+;group","name":"Crew"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"send","method":"send","params":{"chat_guid":"iMessage;+;group","text":"hello","transport":"bridge"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"chat-id","method":"group.rename","params":{"chat_id":1,"name":"Crew"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.vote","params":{"chat_guid":"iMessage;+;group","poll_guid":"poll","option_id":"one"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"sticker","method":"send.sticker","params":{"chat_guid":"iMessage;+;group","file":"/tmp/sticker.png"}}"#
  )

  #expect(actions == [.setDisplayName, .sendMessage])
  #expect(output.responses.count == 2)
  #expect(output.errors.count == 3)
  for envelope in output.errors {
    #expect((envelope["error"] as? [String: Any])?["code"] as? Int == -32002)
  }
}

@Test
func rpcBridgePreflightNeverInvokesWhenReadyLockIsAbsentAndAutoSendFallsBack() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  let invocations = RPCStatusInvocationCounter()
  var sent = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in sent = true },
    resolveSentMessage: resolvedSentMessageFixture,
    invokeBridge: { _, _ in
      invocations.increment()
      return [:]
    },
    isBridgeReady: { false }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bridge","method":"group.rename","params":{"chat_guid":"iMessage;+;group","name":"Crew"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"auto","method":"send","params":{"to":"+123","text":"hello"}}"#)

  #expect(invocations.value == 0)
  #expect(sent == true)
  let bridgeError = try #require(output.errors.first?["error"] as? [String: Any])
  let bridgeData = try #require(bridgeError["data"] as? [String: Any])
  #expect(bridgeData["disposition"] as? String == "not_started")
  #expect(bridgeData["retry_safe"] as? Bool == true)
  #expect(try rpcStatusResult(output, at: 1)["transport"] as? String == "applescript")
}

@Test
func rpcInitializeAndStatusUseControlAndReadSchedulerLanes() {
  #expect(rpcRequestLane(for: "initialize") == .control)
  #expect(rpcRequestLane(for: "status") == .read)
  #expect(rpcRequestLane(for: "watch.unsubscribe") == .control)
  #expect(rpcRequestLane(for: "send") == .mutation)
  #expect(kSupportedRPCMethods.prefix(3) == ["initialize", "status", "watch.unsubscribe"])
}

@Test(.timeLimit(.minutes(1)))
func rpcDegradedStartupWritesOnlyJSONLinesToStdout() async throws {
  let server = RPCServer(
    databasePath: "/tmp/imsg-rpc-status-missing-\(UUID().uuidString)/chat.db",
    verbose: false,
    storeFactory: { _ in throw NSError(domain: "RPCStatusTests", code: 1) },
    isBridgeReady: { false }
  )
  let (lines, input) = makeRuntimeLines()

  let captured = try await StdoutCapture.capture {
    let run = Task { try await server.run(lines: lines) }
    input.yield(#"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
    input.yield(#"{"jsonrpc":"2.0","id":"chats","method":"chats.list"}"#)
    input.finish()
    try await run.value
  }

  let outputLines = captured.output.split(separator: "\n")
  #expect(outputLines.count == 2)
  for line in outputLines {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    #expect(object?["jsonrpc"] as? String == "2.0")
  }
}
