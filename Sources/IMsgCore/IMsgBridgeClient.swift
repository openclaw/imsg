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
  private let pollInterval: Duration
  private let idProvider: @Sendable () -> String
  private let publicationObserver: (@Sendable (BridgeRequestPublication) -> Void)?
  private let classificationObserver: (@Sendable (BridgeRequestPublication) -> Void)?
  private let legacyInvoker:
    (@Sendable (BridgeAction, [String: Any], TimeInterval) async throws -> [String: Any])?

  public init(launcher: MessagesLauncher, useLegacyIPC: Bool? = nil) {
    self.launcher = launcher
    self.pollInterval = .milliseconds(50)
    self.idProvider = { UUID().uuidString }
    self.publicationObserver = nil
    self.classificationObserver = nil
    self.legacyInvoker = nil
    if let override = useLegacyIPC {
      self.useLegacyIPC = override
    } else {
      let env = ProcessInfo.processInfo.environment["IMSG_BRIDGE_LEGACY_IPC"]
      self.useLegacyIPC = (env == "1" || env == "true")
    }
  }

  init(
    testing launcher: MessagesLauncher,
    useLegacyIPC: Bool = false,
    pollInterval: Duration = .milliseconds(50),
    idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
    publicationObserver: (@Sendable (BridgeRequestPublication) -> Void)? = nil,
    classificationObserver: (@Sendable (BridgeRequestPublication) -> Void)? = nil,
    legacyInvoker:
      (@Sendable (BridgeAction, [String: Any], TimeInterval) async throws -> [String: Any])? = nil
  ) {
    self.launcher = launcher
    self.useLegacyIPC = useLegacyIPC
    self.pollInterval = pollInterval
    self.idProvider = idProvider
    self.publicationObserver = publicationObserver
    self.classificationObserver = classificationObserver
    self.legacyInvoker = legacyInvoker
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
    do {
      try Task.checkCancellation()
    } catch {
      throw prepublicationError(
        action: action,
        transport: useLegacyIPC ? .bridgeLegacy : .bridgeV2,
        error: error
      )
    }
    if useLegacyIPC {
      do {
        try await launcher.ensureRunning()
      } catch {
        throw prepublicationError(action: action, transport: .bridgeLegacy, error: error)
      }
      return try await invokeLegacy(action: action, params: params, timeout: timeout)
    }

    do {
      try await launcher.ensureLaunched()
    } catch {
      throw prepublicationError(action: action, transport: .bridgeV2, error: error)
    }
    return try await invokeV2(action: action, params: params, timeout: timeout)
  }

  /// Invoke the already-running v2 bridge without entering any Messages.app launch path.
  /// Long-lived supervised RPC processes use this for probes and bridge methods so a client
  /// capability check can never kill or relaunch Messages.app.
  public func invokeWithoutLaunching(
    action: BridgeAction,
    params: [String: Any] = [:]
  ) async throws -> [String: Any] {
    try Task.checkCancellation()
    guard !useLegacyIPC else {
      throw IMsgBridgeError.bridgeNotReady(
        "non-launching RPC access requires the v2 bridge inbox")
    }
    guard launcher.hasReadyLockFile() else {
      throw IMsgBridgeError.bridgeNotReady(
        "the existing bridge ready lock is absent; run imsg launch explicitly")
    }
    return try await invokeV2(
      action: action,
      params: params,
      timeout: IMsgBridgeProtocol.defaultResponseTimeout(for: action)
    )
  }

}

extension IMsgBridgeClient {
  // MARK: - v2 path

  private func invokeV2(
    action: BridgeAction,
    params: [String: Any],
    timeout: TimeInterval
  ) async throws -> [String: Any] {
    let id = idProvider()
    let envelope: [String: Any] = [
      "v": IMsgBridgeProtocol.version,
      "id": id,
      "action": action.rawValue,
      "params": params,
    ]

    let inboxDir = launcher.bridgeInboxDirectory
    let outboxDir = launcher.bridgeOutboxDirectory

    let tmp = (inboxDir as NSString).appendingPathComponent("\(id).tmp")
    let final = (inboxDir as NSString).appendingPathComponent("\(id).json")
    let outPath = (outboxDir as NSString).appendingPathComponent("\(id).json")

    do {
      try Task.checkCancellation()
      try ensureDirectory(inboxDir)
      try ensureDirectory(outboxDir)
      let payload = try JSONSerialization.data(withJSONObject: envelope, options: [])
      try payload.write(to: URL(fileURLWithPath: tmp))
      try FileManager.default.moveItem(atPath: tmp, toPath: final)
    } catch {
      try? FileManager.default.removeItem(atPath: tmp)
      throw prepublicationError(action: action, transport: .bridgeV2, error: error)
    }

    let publication = BridgeRequestPublication(
      id: id,
      action: action,
      inboxDirectory: inboxDir,
      requestPath: final,
      responsePath: outPath
    )
    publicationObserver?(publication)

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(max(0, timeout))
    while clock.now < deadline {
      let nextPoll = clock.now + pollInterval
      do {
        try await clock.sleep(until: nextPoll < deadline ? nextPoll : deadline)
      } catch {
        if !action.isMutation, error is CancellationError {
          _ = try? resolveInterruptedRequest(
            publication,
            reason: "The caller cancelled while awaiting the bridge response."
          )
          throw CancellationError()
        }
        return try resolveInterruptedRequest(
          publication,
          reason: "The caller cancelled while awaiting the bridge response."
        )
      }
      do {
        if let response = try readV2Response(outPath: outPath) {
          return try unwrapV2Response(response, action: action, transport: .bridgeV2)
        }
      } catch {
        throw postpublicationError(action: action, transport: .bridgeV2, error: error)
      }
      // A vanished published request cannot receive a reply. Normal in-flight
      // work remains as `<id>.json` or `<id>.processing.<pid>`.
      switch requestQueueState(inboxDir: inboxDir, id: id) {
      case .unclaimed:
        continue
      case .claimed:
        continue
      case .unreadable:
        continue
      case .absent:
        return try resolveInterruptedRequest(
          publication,
          reason: "The published bridge request vanished before a response arrived."
        )
      }
    }

    return try resolveInterruptedRequest(
      publication,
      reason: "The bridge response deadline expired."
    )
  }

  private func resolveInterruptedRequest(
    _ publication: BridgeRequestPublication,
    reason: String
  ) throws -> [String: Any] {
    classificationObserver?(publication)
    do {
      if let response = try readV2Response(outPath: publication.responsePath) {
        return try unwrapV2Response(
          response, action: publication.action, transport: .bridgeV2)
      }
    } catch {
      throw postpublicationError(
        action: publication.action, transport: .bridgeV2, error: error)
    }

    switch requestQueueState(inboxDir: publication.inboxDirectory, id: publication.id) {
    case .claimed:
      throw deliveryFailure(
        action: publication.action,
        disposition: .stillInFlight,
        transport: .bridgeV2,
        detail: "\(reason) The bridge still owns a claimed request."
      )
    case .unreadable:
      throw deliveryFailure(
        action: publication.action,
        disposition: .stillInFlight,
        transport: .bridgeV2,
        detail: "\(reason) The bridge inbox could not be inspected; request files were preserved."
      )
    case .absent:
      throw deliveryFailure(
        action: publication.action,
        disposition: .mayHaveCompleted,
        transport: .bridgeV2,
        detail: "\(reason) No request claim or response remains."
      )
    case .unclaimed:
      do {
        try FileManager.default.removeItem(atPath: publication.requestPath)
      } catch {
        return try classifyFailedReclaim(publication, reason: reason)
      }

      do {
        if let response = try readV2Response(outPath: publication.responsePath) {
          return try unwrapV2Response(
            response, action: publication.action, transport: .bridgeV2)
        }
      } catch {
        throw postpublicationError(
          action: publication.action, transport: .bridgeV2, error: error)
      }

      switch requestQueueState(inboxDir: publication.inboxDirectory, id: publication.id) {
      case .absent:
        throw deliveryFailure(
          action: publication.action,
          disposition: .notStarted,
          transport: .bridgeV2,
          detail: "\(reason) The client reclaimed and removed the unclaimed request."
        )
      case .unclaimed, .claimed, .unreadable:
        throw deliveryFailure(
          action: publication.action,
          disposition: .stillInFlight,
          transport: .bridgeV2,
          detail: "\(reason) Queue state changed during reclaim; request files were preserved."
        )
      }
    }
  }

  private func classifyFailedReclaim(
    _ publication: BridgeRequestPublication,
    reason: String
  ) throws -> [String: Any] {
    do {
      if let response = try readV2Response(outPath: publication.responsePath) {
        return try unwrapV2Response(
          response, action: publication.action, transport: .bridgeV2)
      }
    } catch {
      throw postpublicationError(
        action: publication.action, transport: .bridgeV2, error: error)
    }

    switch requestQueueState(inboxDir: publication.inboxDirectory, id: publication.id) {
    case .absent:
      throw deliveryFailure(
        action: publication.action,
        disposition: .mayHaveCompleted,
        transport: .bridgeV2,
        detail: "\(reason) Reclaim lost a race and no request or response remains."
      )
    case .unclaimed, .claimed, .unreadable:
      throw deliveryFailure(
        action: publication.action,
        disposition: .stillInFlight,
        transport: .bridgeV2,
        detail: "\(reason) The unclaimed request could not be owned and removed."
      )
    }
  }

  /// Read and consume a v2 reply if one is present.
  private func readV2Response(outPath: String) throws -> BridgeResponse? {
    guard FileManager.default.fileExists(atPath: outPath) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: outPath))
    } catch {
      throw IMsgBridgeError.ioError("response file could not be read")
    }
    guard data.count > 1 else {
      throw IMsgBridgeError.malformedResponse("empty body")
    }

    guard
      let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        as? [String: Any]
    else {
      throw IMsgBridgeError.malformedResponse("non-object body")
    }
    let response = try BridgeResponse.parse(raw)
    try? FileManager.default.removeItem(atPath: outPath)
    return response
  }

  private func unwrapV2Response(
    _ response: BridgeResponse,
    action: BridgeAction,
    transport: DeliveryTransport
  ) throws -> [String: Any] {
    if response.success {
      return response.data
    }
    let error = IMsgBridgeError.dylibReturnedError(response.error ?? "unknown")
    if action.isMutation {
      throw DeliveryFailure(
        disposition: .mayHaveCompleted,
        transport: transport,
        operation: action.rawValue,
        detail: error.description
      )
    }
    throw error
  }

  /// Classify the request's on-disk state.
  ///
  /// The dylib claims a request by renaming `<id>.json` to
  /// `<id>.processing.<pid>` (see `processV2InboxFile`). The distinction
  /// matters because only a never-claimed request is guaranteed not to have
  /// run.
  func requestQueueState(inboxDir: String, id: String) -> BridgeRequestQueueState {
    let fm = FileManager.default
    if fm.fileExists(atPath: (inboxDir as NSString).appendingPathComponent("\(id).json")) {
      return .unclaimed
    }
    guard let entries = try? fm.contentsOfDirectory(atPath: inboxDir) else {
      return .unreadable
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
      let raw: [String: Any]
      if let legacyInvoker {
        raw = try await legacyInvoker(action, params, timeout)
      } else {
        raw = try await launcher.sendCommand(
          action: action.rawValue,
          params: params,
          timeout: timeout
        )
      }
      let response = try BridgeResponse.parse(raw)
      if response.success {
        return response.data
      }
      return try unwrapV2Response(response, action: action, transport: .bridgeLegacy)
    } catch let failure as DeliveryFailure {
      throw failure
    } catch let error as MessagesLauncherError {
      switch error {
      case .commandTimeout:
        throw deliveryFailure(
          action: action,
          disposition: .stillInFlight,
          transport: .bridgeLegacy,
          detail: "The legacy bridge command timed out without per-request claim proof."
        )
      case .invalidResponse:
        throw deliveryFailure(
          action: action,
          disposition: .mayHaveCompleted,
          transport: .bridgeLegacy,
          detail: error.description
        )
      case .commandNotPublished:
        throw prepublicationError(action: action, transport: .bridgeLegacy, error: error)
      default:
        throw prepublicationError(action: action, transport: .bridgeLegacy, error: error)
      }
    } catch {
      throw postpublicationError(action: action, transport: .bridgeLegacy, error: error)
    }
  }

  private func prepublicationError(
    action: BridgeAction,
    transport: DeliveryTransport,
    error: Error
  ) -> Error {
    if !action.isMutation, error is CancellationError { return CancellationError() }
    guard action.isMutation else {
      return IMsgBridgeError.bridgeNotReady(String(describing: error))
    }
    return DeliveryFailure(
      disposition: .notStarted,
      transport: transport,
      operation: action.rawValue,
      detail: "The bridge request could not be published: \(String(describing: error))"
    )
  }

  private func postpublicationError(
    action: BridgeAction,
    transport: DeliveryTransport,
    error: Error
  ) -> Error {
    if let failure = error as? DeliveryFailure { return failure }
    guard action.isMutation else { return error }
    return DeliveryFailure(
      disposition: .mayHaveCompleted,
      transport: transport,
      operation: action.rawValue,
      detail: "The bridge response was unusable after publication: \(String(describing: error))"
    )
  }

  private func deliveryFailure(
    action: BridgeAction,
    disposition: DeliveryDisposition,
    transport: DeliveryTransport,
    detail: String
  ) -> Error {
    guard action.isMutation else {
      return IMsgBridgeError.timeout(action: action.rawValue)
    }
    return DeliveryFailure(
      disposition: disposition,
      transport: transport,
      operation: action.rawValue,
      detail: detail
    )
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
