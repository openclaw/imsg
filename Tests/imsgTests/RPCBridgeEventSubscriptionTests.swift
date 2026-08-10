import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(.timeLimit(.minutes(1)))
func rpcBridgeEventResponsePrecedesImmediateEvent() async throws {
  let output = TestRPCOutput()
  let event = bridgeEvent("immediate", sequence: 1)
  let server = try makeBridgeEventServer(output: output) { _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(event)
      continuation.finish()
    }
  }

  await server.handleLineForTesting(bridgeSubscribeRequest(id: "subscribe"))
  await output.waitForOutputCount(2)
  await server.subscriptions.waitUntilEmpty()

  #expect(output.outputs[0]["id"] as? String == "subscribe")
  #expect(output.outputs[1]["method"] as? String == "bridge.event")
  let params = try #require(output.outputs[1]["params"] as? [String: Any])
  let payload = try #require(params["event"] as? [String: Any])
  #expect(payload["event"] as? String == "immediate")
  #expect((payload["data"] as? [String: Any])?["sequence"] as? Int == 1)
}

@Test(.timeLimit(.minutes(1)))
func rpcBridgeEventOverflowDrainsAcceptedEventsAndIsNotResumable() async throws {
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(output: output) { _, limit in
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
      for sequence in 1...3 {
        if case .dropped = continuation.yield(bridgeEvent("event", sequence: sequence)) {
          continuation.finish(throwing: IMsgEventTailerOverflowError())
          return
        }
      }
    }
  }

  await server.handleLineForTesting(
    bridgeSubscribeRequest(id: "overflow", params: #"{"buffer_limit":2}"#)
  )
  await output.waitForOutputCount(4)
  await server.subscriptions.waitUntilEmpty()

  #expect(
    output.outputs.map { $0["method"] as? String } == [
      nil, "bridge.event", "bridge.event", "bridge.events.overflow",
    ])
  let terminal = try #require(output.outputs[3]["params"] as? [String: Any])
  #expect(terminal["resumable"] as? Bool == false)
  #expect(terminal["terminal"] as? Bool == true)
  #expect(terminal["resume_after_rowid"] == nil)
}

@Test(.timeLimit(.minutes(1)))
func rpcBridgeEventUnsubscribeIsFinalAndStopsSource() async throws {
  let source = ControlledBridgeEventSource()
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(output: output, streamProvider: source.makeStream)

  await server.handleLineForTesting(bridgeSubscribeRequest(id: "subscribe"))
  await source.waitForStreams(1)
  source.yield(bridgeEvent("before", sequence: 1))
  await output.waitForOutputCount(2)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )
  await source.waitForTerminations(1)

  let count = output.outputs.count
  #expect(source.yield(bridgeEvent("after", sequence: 2)))
  #expect(output.outputs.count == count)
  #expect(output.outputs.last?["id"] as? String == "unsubscribe")
}

@Test(.timeLimit(.minutes(1)))
func rpcEOFStopsBridgeEventSource() async throws {
  let source = ControlledBridgeEventSource()
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(output: output, streamProvider: source.makeStream)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(bridgeSubscribeRequest(id: "subscribe"))
  await source.waitForStreams(1)
  input.finish()
  await source.waitForTerminations(1)
  try await run.value
  #expect(await server.subscriptions.count == 0)
}

@Test
func rpcBridgeEventInactiveBridgeFailsTypedWithoutOpeningSource() async throws {
  let output = TestRPCOutput()
  let source = ControlledBridgeEventSource()
  let server = try makeBridgeEventServer(
    output: output,
    bridgeReady: false,
    streamProvider: source.makeStream
  )

  await server.handleLineForTesting(bridgeSubscribeRequest(id: "inactive"))
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(error["code"] as? Int == -32003)
  #expect(error["message"] as? String == "Bridge events unavailable")
  #expect(await server.subscriptions.count == 0)
}

@Test
func rpcBridgeEventParamsAreStrictAndStatusRequiresUsablePath() async throws {
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(output: output)
  for (id, params) in [
    ("zero", #"{"buffer_limit":0}"#),
    ("large", #"{"buffer_limit":4097}"#),
    ("bool", #"{"buffer_limit":true}"#),
    ("alias", #"{"bufferLimit":2}"#),
  ] {
    await server.handleLineForTesting(bridgeSubscribeRequest(id: id, params: params))
  }
  #expect(output.errors.count == 4)
  #expect(output.errors.allSatisfy { ($0["error"] as? [String: Any])?["code"] as? Int == -32602 })

  let usableOutput = TestRPCOutput()
  let usable = try makeBridgeEventServer(output: usableOutput)
  await usable.handleLineForTesting(#"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
  #expect(rpcStatusMethods(try rpcStatusResult(usableOutput)).contains("bridge.events.subscribe"))

  let unusableOutput = TestRPCOutput()
  let unusable = try makeBridgeEventServer(output: unusableOutput, eventPathUsable: false)
  await unusable.handleLineForTesting(#"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
  let status = try rpcStatusResult(unusableOutput)
  #expect(!rpcStatusMethods(status).contains("bridge.events.subscribe"))
  #expect((status["supported_methods"] as? [String])?.contains("bridge.events.subscribe") == true)
}

@Test(.timeLimit(.minutes(1)))
func rpcSubscriptionCapIsSharedByBridgeEvents() async throws {
  let source = ControlledBridgeEventSource()
  let database = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(
    output: output,
    watchSource: database,
    streamProvider: source.makeStream
  )

  for index in 1...63 {
    await server.handleLineForTesting(bridgeSubscribeRequest(id: "subscribe-\(index)"))
  }
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"database","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await source.waitForStreams(63)
  await database.waitForStreams(1)
  await server.handleLineForTesting(bridgeSubscribeRequest(id: "subscribe-65"))
  await output.waitForOutputCount(65)
  #expect(output.responses.count == 64)
  #expect(output.errors.count == 1)
  #expect(await server.subscriptions.count == 64)

  await server.subscriptions.cancelAll()
  await source.waitForTerminations(63)
  await database.waitForTerminations(1)
}

@Test(.timeLimit(.minutes(1)))
func rpcBridgeEventTerminalReadFailureIsTyped() async throws {
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(output: output) { _, _ in
    throw IMsgEventTailerError.readFailed(path: "/tmp/imsg-events.jsonl", errno: 5)
  }

  await server.handleLineForTesting(bridgeSubscribeRequest(id: "failure"))
  await output.waitForOutputCount(2)
  await server.subscriptions.waitUntilEmpty()
  #expect(output.outputs[1]["method"] as? String == "bridge.events.error")
  let params = try #require(output.outputs[1]["params"] as? [String: Any])
  let error = try #require(params["error"] as? [String: Any])
  #expect(error["code"] as? String == "event_log_read_failed")
  #expect(params["terminal"] as? Bool == true)
}

@Test(.timeLimit(.minutes(1)))
func rpcDatabaseAndBridgeSubscriptionsPreserveOnlyTheirOwnOrder() async throws {
  let database = ControlledWatchSource()
  let bridge = ControlledBridgeEventSource()
  let output = TestRPCOutput()
  let server = try makeBridgeEventServer(
    output: output,
    watchSource: database,
    streamProvider: bridge.makeStream
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"database","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await server.handleLineForTesting(bridgeSubscribeRequest(id: "bridge"))
  await database.waitForStreams(1)
  await bridge.waitForStreams(1)
  database.yield(message(rowID: 1))
  bridge.yield(bridgeEvent("bridge", sequence: 1))
  database.yield(message(rowID: 2))
  bridge.yield(bridgeEvent("bridge", sequence: 2))
  await output.waitForOutputCount(6)

  let databaseOrder = output.notifications.compactMap { notification -> Int64? in
    guard notification["method"] as? String == "message",
      let params = notification["params"] as? [String: Any],
      let payload = params["message"] as? [String: Any]
    else { return nil }
    return payload["id"] as? Int64
  }
  let bridgeOrder = output.notifications.compactMap { notification -> Int? in
    guard notification["method"] as? String == "bridge.event",
      let params = notification["params"] as? [String: Any],
      let event = params["event"] as? [String: Any],
      let data = event["data"] as? [String: Any]
    else { return nil }
    return data["sequence"] as? Int
  }
  #expect(databaseOrder == [1, 2])
  #expect(bridgeOrder == [1, 2])
  await server.subscriptions.cancelAll()
}

private func makeBridgeEventServer(
  output: TestRPCOutput,
  bridgeReady: Bool = true,
  eventPathUsable: Bool = true,
  watchSource: ControlledWatchSource? = nil,
  streamProvider: @escaping RPCBridgeEventStreamProvider = { _, _ in
    AsyncThrowingStream { _ in }
  }
) throws -> RPCServer {
  RPCServer(
    store: try CommandTestDatabase.makeStoreForRPC(),
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      action == .status ? rpcStatusBridgeSnapshot() : [:]
    },
    isBridgeReady: { bridgeReady },
    bridgeEventsPath: "/tmp/imsg-events.jsonl",
    bridgeEventPathUsable: { _ in eventPathUsable },
    bridgeEventStreamProvider: streamProvider,
    watchStreamProvider: { _, _, _, _, _ in
      watchSource?.makeStream() ?? AsyncThrowingStream { $0.finish() }
    }
  )
}

private func bridgeSubscribeRequest(id: String, params: String = "{}") -> String {
  #"{"jsonrpc":"2.0","id":"\#(id)","method":"bridge.events.subscribe","params":\#(params)}"#
}

private func bridgeEvent(_ name: String, sequence: Int) -> IMsgEventTailer.Event {
  IMsgEventTailer.Event(
    timestamp: "2026-08-10T00:00:00Z",
    name: name,
    payloadJSON: Data("{\"sequence\":\(sequence)}".utf8)
  )
}

private func message(rowID: Int64) -> Message {
  Message(
    rowID: rowID,
    chatID: 1,
    sender: "+123",
    text: "message-\(rowID)",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0
  )
}

private final class ControlledBridgeEventSource: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<IMsgEventTailer.Event, Error>.Continuation] = []
  private var streamWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var terminationCount = 0
  private var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func makeStream(
    _ path: String,
    _ bufferLimit: Int
  ) -> AsyncThrowingStream<IMsgEventTailer.Event, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in self?.recordTermination() }
      let ready: [CheckedContinuation<Void, Never>]
      lock.lock()
      continuations.append(continuation)
      ready = streamWaiters.filter { $0.0 <= continuations.count }.map(\.1)
      streamWaiters.removeAll { $0.0 <= continuations.count }
      lock.unlock()
      for continuation in ready {
        continuation.resume()
      }
    }
  }

  @discardableResult
  func yield(_ event: IMsgEventTailer.Event) -> Bool {
    lock.withLock { continuations }.allSatisfy {
      if case .terminated = $0.yield(event) { return true }
      return false
    }
  }

  func waitForStreams(_ count: Int) async {
    await wait(count, streams: true)
  }

  func waitForTerminations(_ count: Int) async {
    await wait(count, streams: false)
  }

  private func wait(_ count: Int, streams: Bool) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      let current = streams ? continuations.count : terminationCount
      if current >= count {
        lock.unlock()
        continuation.resume()
      } else {
        if streams {
          streamWaiters.append((count, continuation))
        } else {
          terminationWaiters.append((count, continuation))
        }
        lock.unlock()
      }
    }
  }

  private func recordTermination() {
    let ready: [CheckedContinuation<Void, Never>]
    lock.lock()
    terminationCount += 1
    ready = terminationWaiters.filter { $0.0 <= terminationCount }.map(\.1)
    terminationWaiters.removeAll { $0.0 <= terminationCount }
    lock.unlock()
    for continuation in ready {
      continuation.resume()
    }
  }
}
