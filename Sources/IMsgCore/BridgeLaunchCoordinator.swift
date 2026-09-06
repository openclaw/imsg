import Foundation

#if os(macOS)
  import Darwin
#endif

/// Serial owner for Messages.app launch/readiness within and across processes.
final class BridgeLaunchCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.bridge-launch-coordinator")
  private let lockFilePath: String?

  init(lockFilePath: String? = nil) {
    self.lockFilePath = lockFilePath
  }

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
            try self.withLaunchLock {
              guard request.isPending else { return }
              if !readinessCheck() {
                try operation()
              }
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
      try withLaunchLock {
        if !readinessCheck() {
          try operation()
        }
      }
    }
  }

  private func withLaunchLock(_ operation: () throws -> Void) throws {
    guard let lockFilePath else {
      try operation()
      return
    }

    #if os(macOS)
      if SecurePath.hasSymlinkComponent(lockFilePath) {
        throw MessagesLauncherError.socketError(
          "launch lock path traverses a symlink: \(lockFilePath)")
      }

      let descriptor = open(lockFilePath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw Self.lockError(action: "open", path: lockFilePath)
      }
      defer { close(descriptor) }

      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw Self.lockError(action: "inspect", path: lockFilePath)
      }
      guard metadata.st_uid == geteuid(), (metadata.st_mode & S_IFMT) == S_IFREG,
        metadata.st_nlink == 1, (metadata.st_mode & 0o077) == 0
      else {
        throw MessagesLauncherError.socketError(
          "launch lock must be an owner-only regular file: \(lockFilePath)")
      }

      guard flock(descriptor, LOCK_EX) == 0 else {
        throw Self.lockError(action: "acquire", path: lockFilePath)
      }
      defer { _ = flock(descriptor, LOCK_UN) }

      try operation()
    #else
      try operation()
    #endif
  }

  #if os(macOS)
    private static func lockError(action: String, path: String) -> MessagesLauncherError {
      let details = String(cString: strerror(errno))
      return .socketError("could not \(action) launch lock \(path): \(details)")
    }
  #endif
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
