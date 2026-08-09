import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

actor RuntimeGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}

actor MutationProbe {
  private let gates: [String: RuntimeGate]
  private var starts: [String] = []
  private var active = 0
  private var maximumActive = 0
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(gates: [String: RuntimeGate] = [:]) {
    self.gates = gates
  }

  func invoke(_ name: String) async {
    active += 1
    maximumActive = max(maximumActive, active)
    starts.append(name)
    resumeStartWaiters()
    if let gate = gates[name] {
      await gate.wait()
    }
    active -= 1
  }

  func waitForStarts(_ count: Int) async {
    if starts.count >= count { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func snapshot() -> (starts: [String], maximumActive: Int) {
    (starts, maximumActive)
  }

  private func resumeStartWaiters() {
    let ready = startWaiters.filter { $0.0 <= starts.count }.map(\.1)
    startWaiters.removeAll { $0.0 <= starts.count }
    for waiter in ready {
      waiter.resume()
    }
  }
}

private actor CompletionFlag {
  private(set) var finished = false

  func markFinished() {
    finished = true
  }
}

final class ControlledWatchSource: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<Message, Error>.Continuation] = []
  private var streamWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var terminationCount = 0
  private var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func makeStream() -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in
        self?.recordTermination()
      }
      let ready: [CheckedContinuation<Void, Never>]
      lock.lock()
      continuations.append(continuation)
      let count = continuations.count
      ready = streamWaiters.filter { $0.0 <= count }.map(\.1)
      streamWaiters.removeAll { $0.0 <= count }
      lock.unlock()
      for waiter in ready {
        waiter.resume()
      }
    }
  }

  @discardableResult
  func yield(_ message: Message) -> Bool {
    let current = snapshotContinuations()
    return current.allSatisfy { continuation in
      if case .terminated = continuation.yield(message) {
        return true
      }
      return false
    }
  }

  func waitForStreams(_ count: Int) async {
    await waitForCount(count, kind: .stream)
  }

  func waitForTerminations(_ count: Int) async {
    await waitForCount(count, kind: .termination)
  }

  private enum CountKind {
    case stream
    case termination
  }

  private func waitForCount(_ count: Int, kind: CountKind) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      let current = kind == .stream ? continuations.count : terminationCount
      if current >= count {
        lock.unlock()
        continuation.resume()
      } else {
        switch kind {
        case .stream:
          streamWaiters.append((count, continuation))
        case .termination:
          terminationWaiters.append((count, continuation))
        }
        lock.unlock()
      }
    }
  }

  private func snapshotContinuations() -> [AsyncThrowingStream<Message, Error>.Continuation] {
    lock.lock()
    defer { lock.unlock() }
    return continuations
  }

  private func recordTermination() {
    let ready: [CheckedContinuation<Void, Never>]
    lock.lock()
    terminationCount += 1
    ready = terminationWaiters.filter { $0.0 <= terminationCount }.map(\.1)
    terminationWaiters.removeAll { $0.0 <= terminationCount }
    lock.unlock()
    for waiter in ready {
      waiter.resume()
    }
  }
}

func makeRuntimeLines() -> (
  RPCLineStream,
  AsyncThrowingStream<String, Error>.Continuation
) {
  var captured: AsyncThrowingStream<String, Error>.Continuation?
  let stream = RPCLineStream { continuation in
    captured = continuation
  }
  return (stream, captured!)
}

func renameRequest(id: String, name: String) -> String {
  """
  {"jsonrpc":"2.0","id":"\(id)","method":"group.rename","params":{"chat_id":1,"name":"\(name)"}}
  """
}

func makeRuntimeServer(
  output: TestRPCOutput,
  probe: MutationProbe,
  watchSource: ControlledWatchSource? = nil,
  readProbe: MutationProbe? = nil,
  contactResolver: any ContactResolving = NoOpContactResolver()
) throws -> RPCServer {
  let store = try CommandTestDatabase.makeStoreForRPC()
  return RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      if action == .setDisplayName {
        await probe.invoke(params["newName"] as? String ?? "")
      } else if action == .checkImessageAvailability {
        await readProbe?.invoke("read")
      }
      return [:]
    },
    isBridgeReady: { true },
    contactResolver: contactResolver,
    watchStreamProvider: { _, _, _, _, _ in
      watchSource?.makeStream()
        ?? AsyncThrowingStream { continuation in continuation.finish() }
    }
  )
}

@Test(.timeLimit(.minutes(1)))
func rpcSuspendedMutationDoesNotBlockReadResponse() async throws {
  let mutationGate = RuntimeGate()
  let probe = MutationProbe(gates: ["blocked": mutationGate])
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "mutation", name: "blocked"))
  await probe.waitForStarts(1)
  input.yield(#"{"jsonrpc":"2.0","id":"read","method":"chats.list","params":{"limit":1}}"#)

  await output.waitForOutputCount(1)
  #expect(output.responses.first?["id"] as? String == "read")

  await mutationGate.open()
  input.finish()
  try await run.value
}

@Test(.timeLimit(.minutes(1)))
func rpcSuspendedMutationDoesNotBlockWatchUnsubscribe() async throws {
  let mutationGate = RuntimeGate()
  let probe = MutationProbe(gates: ["blocked": mutationGate])
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe, watchSource: source)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#)
  await output.waitForOutputCount(1)
  await source.waitForStreams(1)
  input.yield(renameRequest(id: "mutation", name: "blocked"))
  await probe.waitForStarts(1)
  input.yield(
    #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )

  await source.waitForTerminations(1)
  await output.waitForOutputCount(2)
  #expect(output.responses.contains { $0["id"] as? String == "unsubscribe" })

  await mutationGate.open()
  input.finish()
  try await run.value
}

@Test(.timeLimit(.minutes(1)))
func rpcMutationLaneIsFIFOAndDoesNotOverlapWhileReadsComplete() async throws {
  let firstGate = RuntimeGate()
  let secondGate = RuntimeGate()
  let readGate = RuntimeGate()
  let probe = MutationProbe(gates: ["first": firstGate, "second": secondGate])
  let readProbe = MutationProbe(gates: ["read": readGate])
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe, readProbe: readProbe)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "first", name: "first"))
  await probe.waitForStarts(1)
  input.yield(renameRequest(id: "second", name: "second"))
  input.yield(
    #"{"jsonrpc":"2.0","id":"read","method":"handles.check","params":{"address":"+123"}}"#)
  await readProbe.waitForStarts(1)

  #expect(await probe.snapshot().starts == ["first"])

  await firstGate.open()
  await probe.waitForStarts(2)
  #expect(await probe.snapshot().starts == ["first", "second"])
  #expect(await probe.snapshot().maximumActive == 1)
  await output.waitForOutputCount(1)
  #expect(output.responses.first?["id"] as? String == "first")

  await readGate.open()
  await output.waitForOutputCount(2)
  #expect(output.responses.map { $0["id"] as? String } == ["first", "read"])

  await secondGate.open()
  input.finish()
  try await run.value
  #expect(output.responses.map { $0["id"] as? String } == ["first", "read", "second"])
}

@Test(.timeLimit(.minutes(1)))
func rpcReadLaneRunsAtMostFourRequestsConcurrently() async throws {
  let readGate = RuntimeGate()
  let readProbe = MutationProbe(gates: ["read": readGate])
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(
    output: output,
    probe: MutationProbe(),
    readProbe: readProbe
  )
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  for index in 1...5 {
    input.yield(
      """
      {"jsonrpc":"2.0","id":"read-\(index)","method":"handles.check","params":{"address":"+123"}}
      """
    )
  }

  await readProbe.waitForStarts(4)
  #expect(await readProbe.snapshot().starts.count == 4)
  #expect(await readProbe.snapshot().maximumActive == 4)

  await readGate.open()
  await readProbe.waitForStarts(5)
  input.finish()
  try await run.value
  #expect(output.responses.count == 5)
}

@Test(.timeLimit(.minutes(1)))
func rpcEOFStopsSubscriptionsBeforeDrainingAcceptedMutation() async throws {
  let mutationGate = RuntimeGate()
  let probe = MutationProbe(gates: ["blocked": mutationGate])
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe, watchSource: source)
  let completion = CompletionFlag()
  let (lines, input) = makeRuntimeLines()
  let run = Task {
    try await server.run(lines: lines)
    await completion.markFinished()
  }

  input.yield(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#)
  await output.waitForOutputCount(1)
  await source.waitForStreams(1)
  input.yield(renameRequest(id: "mutation", name: "blocked"))
  await probe.waitForStarts(1)

  input.finish()
  await source.waitForTerminations(1)
  #expect(await completion.finished == false)

  await mutationGate.open()
  try await run.value
  #expect(await completion.finished == true)
}

@Test(.timeLimit(.minutes(1)))
func rpcParentCancellationCancelsSubscriptionsButDrainsMutationLane() async throws {
  let firstGate = RuntimeGate()
  let probe = MutationProbe(gates: ["first": firstGate])
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe, watchSource: source)
  let completion = CompletionFlag()
  let (lines, input) = makeRuntimeLines()
  let run = Task {
    do {
      try await server.run(lines: lines)
    } catch is CancellationError {
      await completion.markFinished()
      return
    }
    Issue.record("run() should propagate cancellation")
  }

  input.yield(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#)
  await output.waitForOutputCount(1)
  await source.waitForStreams(1)
  input.yield(renameRequest(id: "first", name: "first"))
  input.yield(renameRequest(id: "second", name: "second"))
  await probe.waitForStarts(1)

  run.cancel()
  await source.waitForTerminations(1)
  #expect(await completion.finished == false)

  await firstGate.open()
  await probe.waitForStarts(2)
  try await run.value
  #expect(await probe.snapshot().starts == ["first", "second"])
  #expect(await completion.finished == true)
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "error" })
}

@Test(.timeLimit(.minutes(1)))
func rpcOutstandingRequestLimitRejectsOnlyIdentifiedExcessWork() async throws {
  let firstGate = RuntimeGate()
  let probe = MutationProbe(gates: ["mutation-0": firstGate])
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "mutation-0", name: "mutation-0"))
  await probe.waitForStarts(1)
  for index in 1..<128 {
    input.yield(renameRequest(id: "mutation-\(index)", name: "mutation-\(index)"))
  }
  input.yield(renameRequest(id: "excess", name: "excess"))
  input.yield(
    #"{"jsonrpc":"2.0","method":"group.rename","params":{"chat_id":1,"name":"notification"}}"#)

  await output.waitForOutputCount(1)
  let busy = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(output.errors.first?["id"] as? String == "excess")
  #expect(busy["code"] as? Int == -32000)

  await firstGate.open()
  input.finish()
  try await run.value
  #expect(await probe.snapshot().starts.count == 128)
  #expect(!probeSnapshotNames(await probe.snapshot()).contains("excess"))
  #expect(!probeSnapshotNames(await probe.snapshot()).contains("notification"))
}

@Test(.timeLimit(.minutes(1)))
func rpcSubscriptionLimitRejectsSixtyFifthSubscription() async throws {
  let probe = MutationProbe()
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(output: output, probe: probe, watchSource: source)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  for index in 1...65 {
    input.yield(
      """
      {"jsonrpc":"2.0","id":"subscribe-\(index)","method":"watch.subscribe","params":{"since_rowid":999}}
      """
    )
  }

  await output.waitForOutputCount(65)
  #expect(output.responses.count == 64)
  #expect(output.errors.count == 1)
  #expect(output.errors.first?["id"] as? String == "subscribe-65")
  #expect(await server.subscriptions.count == 64)

  input.finish()
  await source.waitForTerminations(64)
  try await run.value
  #expect(await server.subscriptions.count == 0)
}

@Test(.timeLimit(.minutes(1)))
func rpcSubscribeResponseAlwaysPrecedesImmediateNotification() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let message = Message(
    rowID: 5,
    chatID: 1,
    sender: "+123",
    text: "immediate",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0
  )
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    watchStreamProvider: { _, _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(message)
        continuation.finish()
      }
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await output.waitForOutputCount(2)
  await server.subscriptions.waitUntilEmpty()

  #expect(output.outputs[0]["id"] as? String == "subscribe")
  #expect(output.outputs[1]["method"] as? String == "message")
}

private func probeSnapshotNames(_ snapshot: (starts: [String], maximumActive: Int)) -> [String] {
  snapshot.starts
}
