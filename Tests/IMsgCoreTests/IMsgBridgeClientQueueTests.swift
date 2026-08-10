import Foundation
import Testing

@testable import IMsgCore

/// A v2 request that vanishes from the inbox without a reply can never be
/// answered: `MessagesLauncher` wipes both queue directories when it relaunches
/// Messages.app with the dylib. These cover the on-disk shapes the poll loop
/// distinguishes, so a live request is never mistaken for a discarded one.
@Suite("IMsgBridgeClient queue detection")
struct IMsgBridgeClientQueueTests {
  private func makeInbox() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("imsg-queue-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true
    )
    return dir
  }

  private func write(_ dir: String, _ name: String) {
    FileManager.default.createFile(
      atPath: (dir as NSString).appendingPathComponent(name),
      contents: Data("{}".utf8)
    )
  }

  private var client: IMsgBridgeClient {
    IMsgBridgeClient(launcher: MessagesLauncher.shared)
  }

  @Test
  func unclaimedRequestIsPending() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    write(inbox, "\(id).json")

    #expect(client.requestQueueState(inboxDir: inbox, id: id) == .unclaimed)
  }

  @Test
  func claimedRequestIsClaimed() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    // The dylib claims a request by renaming it to `<id>.processing.<pid>`
    // (see processV2InboxFile); that is still in flight, not discarded.
    write(inbox, "\(id).processing.4242")

    #expect(client.requestQueueState(inboxDir: inbox, id: id) == .claimed)
  }

  @Test
  func missingRequestIsAbsent() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    // An unrelated request must not keep ours alive.
    write(inbox, "\(UUID().uuidString).json")

    #expect(client.requestQueueState(inboxDir: inbox, id: UUID().uuidString) == .absent)
  }

  @Test
  func unreadableInboxFailsSafeAsPending() {
    // Cannot enumerate: preserve the request and report unknown ownership.
    #expect(
      client.requestQueueState(
        inboxDir: "/nonexistent/imsg-queue-tests", id: UUID().uuidString
      ) == .unreadable
    )
  }

  /// Both observable paths can end absent. The client must not infer delivery
  /// safety from whether it happened to observe the short-lived claim state.
  @Test
  func absentStateDoesNotEncodeClaimHistory() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }

    let neverClaimed = UUID().uuidString
    write(inbox, "\(neverClaimed).json")
    #expect(client.requestQueueState(inboxDir: inbox, id: neverClaimed) == .unclaimed)
    try FileManager.default.removeItem(
      atPath: (inbox as NSString).appendingPathComponent("\(neverClaimed).json")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: neverClaimed) == .absent)

    let claimed = UUID().uuidString
    write(inbox, "\(claimed).json")
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .unclaimed)
    // Dylib claims it.
    try FileManager.default.moveItem(
      atPath: (inbox as NSString).appendingPathComponent("\(claimed).json"),
      toPath: (inbox as NSString).appendingPathComponent("\(claimed).processing.99")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .claimed)
    // Dylib dies; a later scan or relaunch clears the orphaned claim.
    try FileManager.default.removeItem(
      atPath: (inbox as NSString).appendingPathComponent("\(claimed).processing.99")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .absent)
  }

  @Test
  func unclaimedTimeoutIsReclaimedAsNotStarted() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }

    let failure = try await deliveryFailure {
      try await harness.client().invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .notStarted)
    #expect(failure.retrySafe)
    #expect(!FileManager.default.fileExists(atPath: harness.requestPath))
  }

  @Test
  func launchFailureBeforePublicationIsNotStarted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { false },
      launch: { throw MessagesLauncherError.launchFailed("injected launch failure") }
    )
    let client = IMsgBridgeClient(testing: launcher)

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .notStarted)
    #expect(failure.retrySafe)
    #expect(!FileManager.default.fileExists(atPath: launcher.bridgeInboxDirectory))
  }

  @Test
  func claimedTimeoutStaysInFlightAndPreservesClaim() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let claimPath = harness.claimPath(pid: 4242)
    let client = harness.client { publication in
      try? FileManager.default.moveItem(
        atPath: publication.requestPath,
        toPath: claimPath
      )
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .stillInFlight)
    #expect(FileManager.default.fileExists(atPath: claimPath))
  }

  @Test
  func vanishedPublishedRequestIsOutcomeUnknown() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client { publication in
      try? FileManager.default.removeItem(atPath: publication.requestPath)
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .mayHaveCompleted)
    #expect(!failure.retrySafe)
  }

  @Test
  func unreadableQueueIsStillInFlight() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client { publication in
      try? FileManager.default.removeItem(atPath: publication.requestPath)
      try? FileManager.default.removeItem(atPath: publication.inboxDirectory)
      FileManager.default.createFile(
        atPath: publication.inboxDirectory,
        contents: Data("not-a-directory".utf8)
      )
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .stillInFlight)
  }

  @Test
  func finalResponseRecheckWinsClassificationRace() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client(classificationObserver: { publication in
      let response: [String: Any] = [
        "v": 2,
        "id": publication.id,
        "success": true,
        "data": ["messageGuid": "won-race"],
      ]
      let data = try? JSONSerialization.data(withJSONObject: response)
      try? data?.write(to: URL(fileURLWithPath: publication.responsePath))
    })

    let result = try await client.invoke(action: .sendMessage, timeout: 0)

    #expect(result["messageGuid"] as? String == "won-race")
  }

  @Test
  func cancellationUsesSameUnclaimedReclaim() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let (publications, continuation) = AsyncStream<Void>.makeStream()
    let client = harness.client(
      pollInterval: .seconds(30),
      publicationObserver: { _ in continuation.yield(()) }
    )
    let task = Task { () -> DeliveryFailure? in
      do {
        _ = try await client.invoke(action: .sendMessage, timeout: 30)
        return nil
      } catch let failure as DeliveryFailure {
        return failure
      } catch {
        Issue.record("expected DeliveryFailure, got \(error)")
        return nil
      }
    }
    for await _ in publications { break }
    task.cancel()

    guard let failure = await task.value else {
      Issue.record("expected typed cancellation delivery failure")
      return
    }
    #expect(failure.disposition == .notStarted)
    #expect(!FileManager.default.fileExists(atPath: harness.requestPath))
  }

  @Test
  func legacyMutationTimeoutRemainsInFlight() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let launcher = MessagesLauncher(
      containerPath: harness.root.path,
      readyCheck: { true },
      injectedReadyCheck: { true }
    )
    let client = IMsgBridgeClient(
      testing: launcher,
      useLegacyIPC: true,
      legacyInvoker: { action, _, _ in
        throw MessagesLauncherError.commandTimeout(action.rawValue)
      }
    )

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0.01)
    }

    #expect(failure.disposition == .stillInFlight)
    #expect(failure.transport == .bridgeLegacy)
  }

  @Test
  func concurrentReadinessCallsShareOneLaunchAttempt() async throws {
    let state = LaunchAttemptState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { state.checkReady() },
      launch: { state.launch() }
    )
    let client = IMsgBridgeClient(
      testing: launcher,
      pollInterval: .milliseconds(1),
      idProvider: { state.nextID() },
      publicationObserver: { state.writeSuccessResponse(for: $0) }
    )

    let first = Task.detached {
      let result = try await client.invoke(action: .sendMessage, timeout: 1)
      return result["messageGuid"] as? String
    }
    await state.launchStarted.wait()
    let second = Task.detached {
      state.secondTaskScheduled.signal()
      let result = try await client.invoke(action: .sendMessage, timeout: 1)
      return result["messageGuid"] as? String
    }
    await state.secondTaskScheduled.wait()
    state.allowLaunch()

    #expect(try await first.value != nil)
    #expect(try await second.value != nil)
    #expect(state.attemptCount == 1)
  }

}

private enum BridgeClientTestError: Error {
  case expectedDeliveryFailure
}

private func deliveryFailure(
  _ operation: () async throws -> [String: Any]
) async throws -> DeliveryFailure {
  do {
    _ = try await operation()
    throw BridgeClientTestError.expectedDeliveryFailure
  } catch let failure as DeliveryFailure {
    return failure
  }
}

private final class BridgeClientHarness: @unchecked Sendable {
  let root: URL
  private let id = "delivery-test-id"
  private let launcher: MessagesLauncher

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { true },
      injectedReadyCheck: { true }
    )
  }

  var requestPath: String {
    (launcher.bridgeInboxDirectory as NSString).appendingPathComponent("\(id).json")
  }

  func claimPath(pid: Int) -> String {
    (launcher.bridgeInboxDirectory as NSString)
      .appendingPathComponent("\(id).processing.\(pid)")
  }

  func client(
    pollInterval: Duration = .milliseconds(1),
    publicationObserver: (@Sendable (BridgeRequestPublication) -> Void)? = nil,
    classificationObserver: (@Sendable (BridgeRequestPublication) -> Void)? = nil
  ) -> IMsgBridgeClient {
    IMsgBridgeClient(
      testing: launcher,
      pollInterval: pollInterval,
      idProvider: { self.id },
      publicationObserver: publicationObserver,
      classificationObserver: classificationObserver
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private final class LaunchAttemptState: @unchecked Sendable {
  let launchStarted = AsyncTestSignal()
  let secondTaskScheduled = AsyncTestSignal()
  private let launchGate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var ready = false
  private var attempts = 0
  private var nextRequestID = 0

  var attemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts
  }

  func checkReady() -> Bool {
    lock.lock()
    let result = ready
    lock.unlock()
    return result
  }

  func launch() {
    lock.lock()
    attempts += 1
    lock.unlock()
    launchStarted.signal()
    launchGate.wait()
    lock.lock()
    ready = true
    lock.unlock()
  }

  func allowLaunch() {
    launchGate.signal()
  }

  func nextID() -> String {
    lock.lock()
    nextRequestID += 1
    let value = nextRequestID
    lock.unlock()
    return "concurrent-\(value)"
  }

  func writeSuccessResponse(for publication: BridgeRequestPublication) {
    let response: [String: Any] = [
      "v": 2,
      "id": publication.id,
      "success": true,
      "data": ["messageGuid": publication.id],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
    try? data.write(to: URL(fileURLWithPath: publication.responsePath))
  }
}

private final class AsyncTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func signal() {
    let current: [CheckedContinuation<Void, Never>]
    lock.lock()
    signaled = true
    current = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in current { waiter.resume() }
  }
}
