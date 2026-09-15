#if !os(macOS)
  import Foundation

  /// Non-macOS stub. Linux can read copied Messages databases, but there is no
  /// Messages.app process, SIP state, or DYLD injection bridge to launch.
  public final class MessagesLauncher: @unchecked Sendable {
    public static let shared = MessagesLauncher()

    public var dylibPath: String = ".build/release/imsg-bridge-helper.dylib"
    public var bridgeInboxDirectory: String { "/nonexistent/.imsg-rpc/in" }
    public var bridgeOutboxDirectory: String { "/nonexistent/.imsg-rpc/out" }
    public var bridgeEventsFile: String { "/nonexistent/.imsg-events.jsonl" }

    private init() {}

    public func hasReadyLockFile() -> Bool { false }
    public func isInjectedAndReady() -> Bool { false }

    public func ensureRunning() throws {
      try ensureRunning(expectedHelperVersion: nil, force: false)
    }

    public func ensureRunning(
      expectedHelperVersion: String? = nil,
      force: Bool = false
    ) throws {
      _ = expectedHelperVersion
      _ = force
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public func ensureRunning() async throws {
      try await ensureRunning(expectedHelperVersion: nil, force: false)
    }

    public func ensureRunning(
      expectedHelperVersion: String? = nil,
      force: Bool = false
    ) async throws {
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public func ensureLaunched() throws {
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public func ensureLaunched() async throws {
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public func killMessages() {}

    public func sendCommand(action: String, params: [String: Any]) async throws -> [String: Any] {
      try await sendCommand(
        action: action,
        params: params,
        timeout: IMsgBridgeProtocol.defaultResponseTimeout
      )
    }

    public func sendCommand(
      action: String, params: [String: Any], timeout: TimeInterval
    ) async throws -> [String: Any] {
      _ = action
      _ = params
      _ = timeout
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public enum SIPStatus: Equatable, Sendable {
      case enabled
      case disabled
      case unknown(String)
    }

    public static func currentSIPStatus() -> SIPStatus {
      .unknown("System Integrity Protection is a macOS-only concept.")
    }
  }
#endif
