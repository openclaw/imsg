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
    params: [String: Any] = [:]
  ) async throws -> [String: Any] {
    try await invoke(
      action: action,
      params: params,
      timeout: IMsgBridgeProtocol.defaultResponseTimeout(for: action)
    )
  }

  /// Invoke a v2 bridge action with an explicit timeout.
  /// Legacy single-file IPC is only used when explicitly requested through
  /// `IMSG_BRIDGE_LEGACY_IPC=1`.
  public func invoke(
    action: BridgeAction,
    params: [String: Any] = [:],
    timeout: TimeInterval
  ) async throws -> [String: Any] {
    if useLegacyIPC {
      try launcher.ensureRunning()
      return try await invokeLegacy(action: action, params: params, timeout: timeout)
    }

    try launcher.ensureLaunched()
    return try await invokeV2(action: action, params: params, timeout: timeout)
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
      if let response = try readV2Response(outPath: outPath) {
        return try unwrapV2Response(response)
      }
      // No response yet. If the request itself is gone from the inbox, the
      // queue was cleared out from under us — `MessagesLauncher` wipes both
      // queue directories when it relaunches Messages.app with the dylib, so a
      // request that disappears without a reply can never be answered. Polling
      // on to the deadline just burns the caller's full send timeout (2.5
      // minutes for sends) waiting for a reply that no longer has a writer.
      //
      // A request in normal flight is still on disk: unclaimed as
      // `<id>.json`, or claimed by the dylib as `<id>.processing.<pid>`.
      switch requestQueueState(inboxDir: inboxDir, id: id) {
      case .unclaimed:
        continue
      case .claimed:
        continue
      case .absent:
        // Re-check the outbox once: the reply is renamed into place before the
        // claim is dropped, so a reply may have landed between our two checks.
        if let response = try readV2Response(outPath: outPath) {
          return try unwrapV2Response(response)
        }
        // A claim can be created, acted on, and removed between two polls. An
        // absent request therefore never proves that the action did not run,
        // even when this client did not observe the claimed state. Use the
        // existing timeout case so callers cannot mistake this for a
        // retry-safe bridge-not-ready failure.
        throw IMsgBridgeError.timeout(action: action.rawValue)
      }
    }

    try? FileManager.default.removeItem(atPath: final)
    throw IMsgBridgeError.timeout(action: action.rawValue)
  }

  /// Read and consume a v2 reply if one is present.
  private func readV2Response(outPath: String) throws -> BridgeResponse? {
    guard
      let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)),
      data.count > 1
    else { return nil }
    // Best-effort cleanup; ignore failures (dylib may also unlink).
    try? FileManager.default.removeItem(atPath: outPath)

    guard
      let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
    else {
      throw IMsgBridgeError.malformedResponse("non-object body")
    }
    return try BridgeResponse.parse(raw)
  }

  private func unwrapV2Response(_ response: BridgeResponse) throws -> [String: Any] {
    if response.success {
      return response.data
    }
    throw IMsgBridgeError.dylibReturnedError(response.error ?? "unknown")
  }

  /// On-disk state of a request still awaiting a reply.
  enum RequestQueueState: Equatable {
    /// `<id>.json` is present; nothing has read it yet.
    case unclaimed
    /// `<id>.processing.<pid>` is present; the dylib is handling it.
    case claimed
    /// Neither is present, so it was removed by something other than a
    /// completed reply.
    case absent
  }

  /// Classify the request's on-disk state.
  ///
  /// The dylib claims a request by renaming `<id>.json` to
  /// `<id>.processing.<pid>` (see `processV2InboxFile`). The distinction
  /// matters because only a never-claimed request is guaranteed not to have
  /// run.
  func requestQueueState(inboxDir: String, id: String) -> RequestQueueState {
    let fm = FileManager.default
    if fm.fileExists(atPath: (inboxDir as NSString).appendingPathComponent("\(id).json")) {
      return .unclaimed
    }
    guard let entries = try? fm.contentsOfDirectory(atPath: inboxDir) else {
      // Cannot enumerate: treat as still queued rather than ending a live
      // request on a transient read error.
      return .unclaimed
    }
    return entries.contains { $0.hasPrefix("\(id).processing.") } ? .claimed : .absent
  }

  // MARK: - Legacy path

  private func invokeLegacy(
    action: BridgeAction,
    params: [String: Any],
    timeout: TimeInterval
  ) async throws -> [String: Any] {
    do {
      let raw = try await launcher.sendCommand(
        action: action.rawValue,
        params: params,
        timeout: timeout
      )
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
