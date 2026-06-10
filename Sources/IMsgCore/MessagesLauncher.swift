import Foundation

#if os(macOS)
  /// Manages Messages.app lifecycle for DYLD injection.
  ///
  /// Kills any running Messages.app, relaunches with `DYLD_INSERT_LIBRARIES`
  /// pointing to the imsg-bridge dylib, then waits for the lock file that
  /// confirms the dylib is ready for commands.
  public final class MessagesLauncher: @unchecked Sendable {
    public static let shared = MessagesLauncher()

    // File-based IPC paths — must match the paths in IMsgInjected.m.
    // The dylib uses NSHomeDirectory() which resolves to the container path;
    // from outside we construct the full container path ourselves.
    private var commandFile: String {
      containerPath + "/.imsg-command.json"
    }

    private var responseFile: String {
      containerPath + "/.imsg-response.json"
    }

    private var lockFile: String {
      containerPath + "/.imsg-bridge-ready"
    }

    private var containerPath: String {
      NSHomeDirectory() + "/Library/Containers/com.apple.MobileSMS/Data"
    }

    /// Inbox directory for v2 RPC requests (`<uuid>.json` files dropped here by
    /// the CLI; consumed by the dylib).
    public var bridgeInboxDirectory: String {
      containerPath + "/" + IMsgBridgeProtocol.rpcDirectoryName + "/"
        + IMsgBridgeProtocol.inboxDirectoryName
    }

    /// Outbox directory for v2 RPC responses (`<uuid>.json` files written by
    /// the dylib; consumed by the CLI).
    public var bridgeOutboxDirectory: String {
      containerPath + "/" + IMsgBridgeProtocol.rpcDirectoryName + "/"
        + IMsgBridgeProtocol.outboxDirectoryName
    }

    /// Path to the dylib's append-only event log.
    public var bridgeEventsFile: String {
      containerPath + "/" + IMsgBridgeProtocol.eventsFileName
    }

    private let messagesAppPath =
      "/System/Applications/Messages.app/Contents/MacOS/Messages"
    private let queue = DispatchQueue(label: "imsg.messages.launcher")
    private let lock = NSLock()

    /// Path to the dylib to inject.
    public var dylibPath: String = ".build/release/imsg-bridge-helper.dylib"

    private init() {
      if let path = BridgeHelperLocator.resolve() {
        self.dylibPath = path
      }
    }

    /// Check if Messages.app has published the bridge-ready lock file.
    public func hasReadyLockFile() -> Bool {
      FileManager.default.fileExists(atPath: lockFile)
    }

    /// Check if Messages.app is running with our dylib (lock file exists and responds to ping).
    public func isInjectedAndReady() -> Bool {
      guard hasReadyLockFile() else {
        return false
      }
      do {
        let response = try sendCommandSync(
          action: "ping",
          params: [:],
          timeout: IMsgBridgeProtocol.defaultResponseTimeout
        )
        return response["success"] as? Bool == true
      } catch {
        return false
      }
    }

    /// Ensure Messages.app is running with our dylib injected.
    public func ensureRunning() throws {
      if isInjectedAndReady() { return }
      try launchInjectedMessages()
    }

    /// Ensure Messages.app is launched with the helper without touching legacy IPC.
    public func ensureLaunched() throws {
      if hasReadyLockFile() { return }
      try launchInjectedMessages()
    }

    private func launchInjectedMessages() throws {
      switch Self.currentSIPStatus() {
      case .disabled:
        break
      case .enabled:
        throw MessagesLauncherError.sipEnabled
      case .unknown(let details):
        throw MessagesLauncherError.sipStatusUnknown(details)
      }

      guard FileManager.default.fileExists(atPath: dylibPath) else {
        throw MessagesLauncherError.dylibNotFound(dylibPath)
      }

      killMessages()
      Thread.sleep(forTimeInterval: 1.0)

      // Clean up stale IPC files
      try? FileManager.default.removeItem(atPath: commandFile)
      try? FileManager.default.removeItem(atPath: responseFile)
      try? FileManager.default.removeItem(atPath: lockFile)

      // Pre-create v2 RPC queue directories so the dylib can FSEvent-watch them
      // immediately on startup (FSEventStream registration on a missing path
      // silently fails to deliver events).
      try ensureSecureQueueDirectory(bridgeInboxDirectory)
      try ensureSecureQueueDirectory(bridgeOutboxDirectory)
      try cleanQueueDirectory(bridgeInboxDirectory)
      try cleanQueueDirectory(bridgeOutboxDirectory)

      try launchWithInjection()
      try waitForReady(timeout: 15.0)
    }

    private func ensureSecureQueueDirectory(_ path: String) throws {
      if SecurePath.hasSymlinkComponent(path) {
        throw MessagesLauncherError.socketError("RPC queue path traverses a symlink: \(path)")
      }
      do {
        try FileManager.default.createDirectory(
          atPath: path,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        if SecurePath.hasSymlinkComponent(path) {
          throw MessagesLauncherError.socketError(
            "RPC queue path traverses a symlink (post-mkdir): \(path)")
        }
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: path)
      } catch let error as MessagesLauncherError {
        throw error
      } catch {
        throw MessagesLauncherError.socketError("mkdir \(path): \(error.localizedDescription)")
      }
    }

    private func cleanQueueDirectory(_ path: String) throws {
      if SecurePath.hasSymlinkComponent(path) {
        throw MessagesLauncherError.socketError("RPC queue path traverses a symlink: \(path)")
      }
      let entries = try FileManager.default.contentsOfDirectory(atPath: path)
      for entry in entries {
        try FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(entry))
      }
    }

    /// Kill Messages.app if running.
    public func killMessages() {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
      task.arguments = ["Messages"]
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try? task.run()
      task.waitUntilExit()
    }

    /// Send a command asynchronously.
    public func sendCommand(
      action: String, params: [String: Any]
    ) async throws -> [String: Any] {
      try await sendCommand(
        action: action,
        params: params,
        timeout: IMsgBridgeProtocol.defaultResponseTimeout
      )
    }

    /// Send a command asynchronously with an explicit response timeout.
    public func sendCommand(
      action: String, params: [String: Any], timeout: TimeInterval
    ) async throws -> [String: Any] {
      try ensureRunning()
      // Serialize params to JSON data to cross the Sendable boundary safely
      let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[String: Any], Error>) in
        queue.async {
          do {
            let deserializedParams =
              (try? JSONSerialization.jsonObject(with: paramsData, options: []))
              as? [String: Any] ?? [:]
            let response = try self.sendCommandSync(
              action: action,
              params: deserializedParams,
              timeout: timeout
            )
            continuation.resume(returning: response)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    // MARK: - Private

    private static func csrutilStatusOutput() -> String? {
      let task = Process()
      let output = Pipe()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
      task.arguments = ["status"]
      task.standardOutput = output
      task.standardError = output
      do {
        try task.run()
      } catch {
        return nil
      }
      task.waitUntilExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum SIPStatus: Equatable, Sendable {
      case enabled
      case disabled
      case unknown(String)
    }

    public static func currentSIPStatus() -> SIPStatus {
      guard let output = csrutilStatusOutput(), !output.isEmpty else {
        return .unknown("Unable to run `csrutil status`.")
      }
      let lowered = output.lowercased()
      if lowered.contains("disabled") {
        return .disabled
      }
      if lowered.contains("enabled") {
        return .enabled
      }
      return .unknown(output)
    }

    private func launchWithInjection() throws {
      let absoluteDylibPath =
        dylibPath.hasPrefix("/")
        ? dylibPath
        : FileManager.default.currentDirectoryPath + "/" + dylibPath

      guard FileManager.default.fileExists(atPath: absoluteDylibPath) else {
        throw MessagesLauncherError.dylibNotFound(absoluteDylibPath)
      }

      let task = Process()
      task.executableURL = URL(fileURLWithPath: messagesAppPath)

      var environment = ProcessInfo.processInfo.environment
      environment["DYLD_INSERT_LIBRARIES"] = absoluteDylibPath
      task.environment = environment

      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice

      do {
        try task.run()
      } catch {
        throw MessagesLauncherError.launchFailed(error.localizedDescription)
      }
    }

    private func waitForReady(timeout: TimeInterval) throws {
      let deadline = Date().addingTimeInterval(timeout)

      while Date() < deadline {
        if FileManager.default.fileExists(atPath: lockFile) {
          Thread.sleep(forTimeInterval: 0.5)
          return
        }
        Thread.sleep(forTimeInterval: 0.5)
      }

      throw MessagesLauncherError.socketTimeout
    }

    private func sendCommandSync(
      action: String, params: [String: Any], timeout: TimeInterval
    ) throws -> [String: Any] {
      lock.lock()
      defer { lock.unlock() }

      let command: [String: Any] = [
        "id": Int(Date().timeIntervalSince1970 * 1000),
        "action": action,
        "params": params,
      ]

      let jsonData = try JSONSerialization.data(withJSONObject: command, options: [])
      try jsonData.write(to: URL(fileURLWithPath: commandFile))

      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)

        guard
          let responseData = try? Data(contentsOf: URL(fileURLWithPath: responseFile)),
          responseData.count > 2
        else { continue }

        // Check if command file was cleared (indicates processing completed)
        if let cmdData = try? Data(contentsOf: URL(fileURLWithPath: commandFile)),
          cmdData.count <= 2
        {
          guard
            let response = try? JSONSerialization.jsonObject(with: responseData, options: [])
              as? [String: Any]
          else {
            throw MessagesLauncherError.invalidResponse
          }
          // Clear response file
          try? "".write(toFile: responseFile, atomically: true, encoding: .utf8)
          return response
        }
      }

      throw MessagesLauncherError.socketError("Timeout waiting for response")
    }
  }
#else
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
      throw MessagesLauncherError.launchFailed("Messages.app is only available on macOS.")
    }

    public func ensureLaunched() throws {
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

public enum MessagesLauncherError: Error, CustomStringConvertible {
  case dylibNotFound(String)
  case launchFailed(String)
  case sipEnabled
  case sipStatusUnknown(String)
  case socketTimeout
  case socketError(String)
  case invalidResponse

  public var description: String {
    switch self {
    case .dylibNotFound(let path):
      return "imsg-bridge-helper.dylib not found at \(path). Build with: make build-dylib"
    case .launchFailed(let reason):
      return "Failed to launch Messages.app: \(reason)"
    case .sipEnabled:
      return
        "System Integrity Protection (SIP) is enabled. "
        + "Refusing to inject into Messages.app. "
        + "Disable SIP in Recovery mode before using `imsg launch`."
    case .sipStatusUnknown(let details):
      return
        "Unable to determine SIP status. "
        + "Refusing to inject into Messages.app. "
        + "Details: \(details)"
    case .socketTimeout:
      return
        "Timeout waiting for Messages.app to initialize. "
        + "Ensure SIP is disabled and Messages.app has necessary permissions."
    case .socketError(let reason):
      return "IPC error: \(reason)"
    case .invalidResponse:
      return "Invalid response from Messages.app helper"
    }
  }
}
