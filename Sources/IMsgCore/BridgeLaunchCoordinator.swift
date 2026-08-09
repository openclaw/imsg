import Foundation

/// Process-local single-flight owner for Messages.app launch/readiness.
final class BridgeLaunchCoordinator: @unchecked Sendable {
  private let condition = NSCondition()
  private var launchInProgress = false
  private var generation: UInt64 = 0
  private var lastError: Error?
  private var lastSucceeded = false

  func run(
    readinessCheck: () -> Bool,
    operation: () throws -> Void
  ) throws {
    condition.lock()
    if readinessCheck() {
      condition.unlock()
      return
    }

    if launchInProgress {
      let observedGeneration = generation
      while launchInProgress, generation == observedGeneration {
        condition.wait()
      }
      let succeeded = lastSucceeded
      let error = lastError
      condition.unlock()
      if succeeded { return }
      if let error { throw error }
      throw MessagesLauncherError.launchFailed("concurrent launch did not complete")
    }

    launchInProgress = true
    let attemptGeneration = generation + 1
    condition.unlock()

    let result = Result { try operation() }

    condition.lock()
    generation = attemptGeneration
    launchInProgress = false
    switch result {
    case .success:
      lastSucceeded = true
      lastError = nil
    case .failure(let error):
      lastSucceeded = false
      lastError = error
    }
    condition.broadcast()
    condition.unlock()
    try result.get()
  }
}
