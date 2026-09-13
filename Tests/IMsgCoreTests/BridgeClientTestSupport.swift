import Foundation
import Testing

@testable import IMsgCore

enum BridgeClientTestError: Error, Equatable {
  case expectedDeliveryFailure
  case launchFailed
}

func deliveryFailure(
  _ operation: () async throws -> [String: Any]
) async throws -> DeliveryFailure {
  do {
    _ = try await operation()
    throw BridgeClientTestError.expectedDeliveryFailure
  } catch let failure as DeliveryFailure {
    return failure
  }
}

final class BridgeClientHarness: @unchecked Sendable {
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

final class LaunchAttemptState: @unchecked Sendable {
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
    let shouldWait = attempts == 1
    lock.unlock()
    launchStarted.signal()
    if shouldWait {
      launchGate.wait()
    }
    lock.lock()
    ready = true
    lock.unlock()
  }

  func allowLaunch() {
    launchGate.signal()
  }

  func markReady() {
    lock.lock()
    attempts += 1
    ready = true
    lock.unlock()
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

final class AsyncTestSignal: @unchecked Sendable {
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
