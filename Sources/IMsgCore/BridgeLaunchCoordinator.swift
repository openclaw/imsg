import Foundation

/// Process-local serial owner for Messages.app launch/readiness.
final class BridgeLaunchCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.bridge-launch-coordinator")

  func run(
    readinessCheck: @escaping @Sendable () -> Bool,
    operation: @escaping @Sendable () throws -> Void
  ) async throws {
    let request = AsyncLaunchRequest()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        request.install(continuation)
        queue.async {
          guard request.isPending else { return }
          let result = Result {
            if !readinessCheck() {
              try operation()
            }
          }
          request.resume(with: result)
        }
      }
    } onCancel: {
      request.cancel()
    }
  }

  func runSynchronously(
    readinessCheck: @Sendable () -> Bool,
    operation: @Sendable () throws -> Void
  ) throws {
    try queue.sync {
      if !readinessCheck() {
        try operation()
      }
    }
  }
}

private final class AsyncLaunchRequest: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<Void, Error>)
    case completed
  }

  private let lock = NSLock()
  private var state = State.waiting

  var isPending: Bool {
    lock.withLock {
      if case .installed = state { return true }
      return false
    }
  }

  func install(_ continuation: CheckedContinuation<Void, Error>) {
    let cancelled = lock.withLock { () -> Bool in
      switch state {
      case .waiting:
        state = .installed(continuation)
        return false
      case .completed:
        return true
      case .installed:
        preconditionFailure("continuation installed more than once")
      }
    }
    if cancelled {
      continuation.resume(throwing: CancellationError())
    }
  }

  func cancel() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      switch state {
      case .waiting:
        state = .completed
        return nil
      case .installed(let continuation):
        state = .completed
        return continuation
      case .completed:
        return nil
      }
    }
    continuation?.resume(throwing: CancellationError())
  }

  func resume(with result: Result<Void, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard case .installed(let continuation) = state else { return nil }
      state = .completed
      return continuation
    }
    continuation?.resume(with: result)
  }
}
