import Foundation
import Testing

@testable import IMsgCore

@Suite("IMsgBridgeClient non-launching invocation")
struct IMsgBridgeClientNonLaunchingTests {
  @Test
  func nonLaunchingInvokeDoesNotEnterLauncherWhenReadyLockIsAbsent() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launch = LockedInvocationFlag()
    let launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { false },
      launch: { launch.record() }
    )
    let client = IMsgBridgeClient(testing: launcher)

    do {
      _ = try await client.invokeWithoutLaunching(action: .status)
      Issue.record("expected bridge-not-ready error")
    } catch let error as IMsgBridgeError {
      guard case .bridgeNotReady = error else {
        Issue.record("expected bridge-not-ready error, got \(error)")
        return
      }
    } catch {
      Issue.record("expected IMsgBridgeError, got \(error)")
    }

    #expect(launch.count == 0)
    #expect(!FileManager.default.fileExists(atPath: launcher.bridgeInboxDirectory))
  }
}

private final class LockedInvocationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var count: Int {
    lock.withLock { storage }
  }

  func record() {
    lock.withLock { storage += 1 }
  }
}
