import Foundation
import Testing

@testable import IMsgCore

extension IMsgBridgeClientQueueTests {
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

  @Test
  func independentLaunchersShareOneLaunchAttempt() async throws {
    let state = LaunchAttemptState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let makeLauncher = {
      MessagesLauncher(
        containerPath: root.path,
        readyCheck: { state.checkReady() },
        launch: { state.launch() })
    }
    let firstLauncher = makeLauncher()
    let secondLauncher = makeLauncher()

    let first = Task.detached { try await firstLauncher.ensureLaunched() }
    await state.launchStarted.wait()
    let second = Task.detached {
      state.secondTaskScheduled.signal()
      try await secondLauncher.ensureLaunched()
    }
    await state.secondTaskScheduled.wait()
    state.allowLaunch()

    try await first.value
    try await second.value
    #expect(state.attemptCount == 1)
    #expect(FileManager.default.fileExists(atPath: root.path))
  }

  @Test
  func launchFailureReleasesSharedLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let failingLauncher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { false },
      launch: { throw BridgeClientTestError.launchFailed })
    #expect(throws: BridgeClientTestError.launchFailed) {
      try failingLauncher.ensureLaunched()
    }

    let state = LaunchAttemptState()
    let recoveringLauncher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { state.checkReady() },
      launch: { state.markReady() })
    try recoveringLauncher.ensureLaunched()

    #expect(state.attemptCount == 1)
  }
}
