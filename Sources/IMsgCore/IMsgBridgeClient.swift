import Foundation

/// One-shot RPC client for the v2 bridge protocol.
///
/// Each call atomically drops a `<uuid>.json` request file into
/// `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-rpc/in/`, then polls
/// `out/<uuid>.json` until the dylib responds (or `timeout` elapses).
///
/// The dylib is shared across CLI invocations: many concurrent `imsg`
/// processes can drop requests at once and each gets routed back to the
/// correct caller via the UUID. There is no global lock on the CLI side.
public final class IMsgBridgeClient: @unchecked Sendable {
  public static let shared = IMsgBridgeClient(launcher: MessagesLauncher.shared)

  private let launcher: MessagesLauncher
  private let useLegacyIPC: Bool

  /// Polling cadence while waiting for a response file to appear.
  private let pollInterval: TimeInterval = 0.05

  public init(launcher: MessagesLauncher, useLegacyIPC: Bool? = nil) {
    self.launcher = launcher
    if let override = useLegacyIPC {
      self.useLegacyIPC = override
    } else {
      let env = ProcessInfo.processInfo.environment["IMSG_BRIDGE_LEGACY_IPC"]
      self.useLegacyIPC = (env == "1" || env == "true")
    }
  }

  /// Whether the dylib is currently injected and has published its ready lock.
  public func isReady() -> Bool {
    launcher.hasReadyLockFile()
  }

  // MARK: - High-level API

  /// Invoke a v2 bridge action and return its `data` payload on success.
  /// Legacy single-file IPC is only used when explicitly requested through
  /// `IMSG_BRIDGE_LEGACY_IPC=1`.
  public func invoke(
    action: BridgeAction,
    params: [String: Any] = [:],
    timeout: TimeInterval? = nil
  ) async throws -> [String: Any] {
    let effectiveTimeout = timeout ?? IMsgBridgeProtocol.defaultResponseTimeout(for: action)
    if useLegacyIPC {
      try launcher.ensureRunning()
      return try await invokeLegacy(action: action, params: params)
    }

    try launcher.ensureLaunched()
    return try await invokeV2(action: action, params: params, timeout: effectiveTimeout)
  }

  // MARK: - v2 path

  private func invokeV2(
    action: BridgeAction,
    params: [String: Any],
    timeout: TimeInterval
  ) async throws -> [String: Any] {
    let id = UUID().uuidString
    let envelope: [String: Any] = [
      "v": IMsgBridgeProtocol.version,
      "id": id,
      "action": action.rawValue,
      "params": params,
    ]

    let inboxDir = launcher.bridgeInboxDirectory
    let outboxDir = launcher.bridgeOutboxDirectory
    try ensureDirectory(inboxDir)
    try ensureDirectory(outboxDir)

    let tmp = (inboxDir as NSString).appendingPathComponent("\(id).tmp")
    let final = (inboxDir as NSString).appendingPathComponent("\(id).json")
    let outPath = (outboxDir as NSString).appendingPathComponent("\(id).json")

    let payload = try JSONSerialization.data(withJSONObject: envelope, options: [])
    try payload.write(to: URL(fileURLWithPath: tmp))
    try FileManager.default.moveItem(atPath: tmp, toPath: final)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
      guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)),
        data.count > 1
      else { continue }
      // Best-effort cleanup; ignore failures (dylib may also unlink).
      try? FileManager.default.removeItem(atPath: outPath)

      guard
        let raw = try? JSONSerialization.jsonObject(with: data, options: [])
          as? [String: Any]
      else {
        throw IMsgBridgeError.malformedResponse("non-object body")
      }
      let response = try BridgeResponse.parse(raw)
      if response.success {
        return response.data
      }
      throw IMsgBridgeError.dylibReturnedError(response.error ?? "unknown")
    }

    try? FileManager.default.removeItem(atPath: final)
    throw IMsgBridgeError.timeout(action: action.rawValue)
  }

  // MARK: - Legacy path

  private func invokeLegacy(
    action: BridgeAction,
    params: [String: Any]
  ) async throws -> [String: Any] {
    do {
      let raw = try await launcher.sendCommand(action: action.rawValue, params: params)
      let response = try BridgeResponse.parse(raw)
      if response.success {
        return response.data
      }
      throw IMsgBridgeError.dylibReturnedError(response.error ?? "unknown")
    } catch let error as MessagesLauncherError {
      throw IMsgBridgeError.bridgeNotReady(error.description)
    }
  }

  private func ensureDirectory(_ path: String) throws {
    if SecurePath.hasSymlinkComponent(path) {
      throw IMsgBridgeError.ioError("\(path) traverses a symlink")
    }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
      if isDir.boolValue { return }
      throw IMsgBridgeError.ioError("\(path) exists and is not a directory")
    }
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if SecurePath.hasSymlinkComponent(path) {
        throw IMsgBridgeError.ioError("\(path) traverses a symlink (post-mkdir)")
      }
    } catch let error as IMsgBridgeError {
      throw error
    } catch {
      throw IMsgBridgeError.ioError("mkdir \(path): \(error.localizedDescription)")
    }
  }
}
