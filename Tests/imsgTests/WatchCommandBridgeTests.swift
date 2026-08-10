import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private enum WatchCommandBridgeTestError: Error {
  case bridge
  case database
  case setup
}

private actor WatchCommandBridgeGate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    guard !open else { return }
    open = true
    let ready = waiters
    waiters.removeAll()
    for waiter in ready { waiter.resume() }
  }
}

private actor GatedWatchMessageSequence {
  private let gate: WatchCommandBridgeGate
  private let messages: [Message]
  private var index = 0

  init(gate: WatchCommandBridgeGate, messages: [Message]) {
    self.gate = gate
    self.messages = messages
  }

  func next() async -> Message? {
    await gate.wait()
    guard index < messages.count else { return nil }
    defer { index += 1 }
    return messages[index]
  }
}

private final class WatchCommandStreamSource<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var terminated = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

  func makeStream() -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in self?.finish() }
      let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
        started = true
        defer { startWaiters.removeAll() }
        return startWaiters
      }
      for waiter in ready { waiter.resume() }
    }
  }

  func waitForStart() async {
    if lock.withLock({ started }) { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if started {
        lock.unlock()
        continuation.resume()
      } else {
        startWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func waitForTermination() async {
    if lock.withLock({ terminated }) { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if terminated {
        lock.unlock()
        continuation.resume()
      } else {
        terminationWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func finish() {
    let ready: [CheckedContinuation<Void, Never>]
    lock.lock()
    terminated = true
    ready = terminationWaiters
    terminationWaiters.removeAll()
    lock.unlock()
    for continuation in ready {
      continuation.resume()
    }
  }
}

private func bridgeWatchValues() -> ParsedValues {
  ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["bbEvents"]
  )
}

private func watchCommandBridgeMessage(rowID: Int64, text: String) -> Message {
  Message(
    rowID: rowID,
    chatID: 1,
    sender: "+123",
    text: text,
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
}

private func singleBridgeWatchMessageStream(
  _ message: Message
) -> (
  MessageWatcher,
  Int64?,
  Int64?,
  MessageWatcherConfiguration,
  MessageFilter
) -> AsyncThrowingStream<Message, Error> {
  return { _, _, _, _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(message)
      continuation.finish()
    }
  }
}

@Test
func watchCommandRunsDatabaseStreamWhenBridgeSetupFails() async throws {
  let values = bridgeWatchValues()
  let store = try CommandTestDatabase.makeStoreForRPC()
  let message = watchCommandBridgeMessage(
    rowID: 1,
    text: "database-after-bridge-setup-error"
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleBridgeWatchMessageStream(message),
      bridgeStreamProvider: { _ in throw WatchCommandBridgeTestError.setup }
    )
  }

  #expect(output.contains(message.text))
}

@Test
func watchCommandKeepsDatabaseStreamRunningAfterBridgeError() async throws {
  let values = bridgeWatchValues()
  let store = try CommandTestDatabase.makeStoreForRPC()
  let gate = WatchCommandBridgeGate()
  let messages = [
    watchCommandBridgeMessage(rowID: 1, text: "database-after-bridge-error-1"),
    watchCommandBridgeMessage(rowID: 2, text: "database-after-bridge-error-2"),
  ]
  let sequence = GatedWatchMessageSequence(gate: gate, messages: messages)

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: { _, _, _, _, _ in
        AsyncThrowingStream(unfolding: { await sequence.next() })
      },
      bridgeStreamProvider: { _ in
        AsyncThrowingStream(unfolding: {
          await gate.release()
          throw WatchCommandBridgeTestError.bridge
        })
      }
    )
  }

  #expect(output.contains(messages[0].text))
  #expect(output.contains(messages[1].text))
}

@Test(.timeLimit(.minutes(1)))
func watchCommandDatabaseErrorCancelsBridgeAndPropagates() async throws {
  let values = bridgeWatchValues()
  let store = try CommandTestDatabase.makeStoreForRPC()
  let bridge = WatchCommandStreamSource<IMsgEventTailer.Event>()

  do {
    _ = try await StdoutCapture.capture {
      try await WatchCommand.run(
        values: values,
        runtime: RuntimeOptions(parsedValues: values),
        storeFactory: { _ in store },
        contactResolverFactory: { NoOpContactResolver() },
        streamProvider: { _, _, _, _, _ in
          AsyncThrowingStream { $0.finish(throwing: WatchCommandBridgeTestError.database) }
        },
        bridgeStreamProvider: { _ in bridge.makeStream() }
      )
    }
    Issue.record("Expected the database error to propagate")
  } catch WatchCommandBridgeTestError.database {
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  await bridge.waitForTermination()
}

@Test(.timeLimit(.minutes(1)))
func watchCommandCancellationStopsDatabaseAndBridgeStreams() async throws {
  let values = bridgeWatchValues()
  let store = try CommandTestDatabase.makeStoreForRPC()
  let database = WatchCommandStreamSource<Message>()
  let bridge = WatchCommandStreamSource<IMsgEventTailer.Event>()
  let run = Task {
    try await WatchCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: { _, _, _, _, _ in database.makeStream() },
      bridgeStreamProvider: { _ in bridge.makeStream() }
    )
  }

  await database.waitForStart()
  await bridge.waitForStart()
  run.cancel()
  do {
    try await run.value
    Issue.record("Expected cancellation to propagate")
  } catch is CancellationError {
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
  await database.waitForTermination()
  await bridge.waitForTermination()
}
