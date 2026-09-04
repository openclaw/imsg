import Foundation

#if os(macOS)
  /// Sends typing indicators for iMessage chats.
  ///
  /// Prefers the IMCore bridge (via DYLD injection into Messages.app) which
  /// is reliable on stock macOS with SIP disabled. Falls back to direct
  /// IMCore access via `dlopen` when the bridge is unavailable.
  public struct TypingIndicator: Sendable {
    private static let daemonConnectionTracker = DaemonConnectionTracker()

    /// Start showing the typing indicator for a chat.
    /// - Parameter chatIdentifier: e.g. `"iMessage;-;+14155551212"` or a chat GUID.
    /// - Throws: `IMsgError.typingIndicatorFailed` if both bridge and direct IMCore fail.
    public static func startTyping(chatIdentifier: String) throws {
      try setTyping(chatIdentifier: chatIdentifier, isTyping: true)
    }

    /// Stop showing the typing indicator for a chat.
    /// - Parameter chatIdentifier: The chat identifier string.
    /// - Throws: `IMsgError.typingIndicatorFailed` if both bridge and direct IMCore fail.
    public static func stopTyping(chatIdentifier: String) throws {
      try setTyping(chatIdentifier: chatIdentifier, isTyping: false)
    }

    /// Show typing indicator for a duration, then automatically stop.
    /// - Parameters:
    ///   - chatIdentifier: The chat identifier string.
    ///   - duration: Seconds to show the typing indicator.
    public static func typeForDuration(chatIdentifier: String, duration: TimeInterval) async throws
    {
      try await typeForDuration(
        chatIdentifier: chatIdentifier,
        duration: duration,
        startTyping: { try startTyping(chatIdentifier: $0) },
        stopTyping: { try stopTyping(chatIdentifier: $0) },
        sleep: { try await Task.sleep(nanoseconds: $0) }
      )
    }

    // MARK: - Private

    private static func setTyping(chatIdentifier: String, isTyping: Bool) throws {
      // Prefer the bridge (dylib injected into Messages.app)
      let bridge = IMCoreBridge.shared
      if bridge.isAvailable {
        do {
          try setTypingViaBridge(bridge: bridge, chatIdentifier: chatIdentifier, isTyping: isTyping)
          return
        } catch let failure as DeliveryFailure {
          guard failure.retrySafe else { throw failure }
          // The bridge owner proved it never dispatched, so direct IMCore is safe.
        } catch {
          // Without an authoritative delivery fact, a second mutation is unsafe.
          throw error
        }
      }

      // Fallback: direct IMCore access (requires AMFI disabled + XPC plist)
      try setTypingDirect(chatIdentifier: chatIdentifier, isTyping: isTyping)
    }

    /// Synchronous wrapper for the async bridge call using a Sendable result box.
    private static func setTypingViaBridge(
      bridge: IMCoreBridge, chatIdentifier: String, isTyping: Bool
    ) throws {
      try waitForBridgeOperation(operation: "typing") {
        try await bridge.setTyping(for: chatIdentifier, typing: isTyping)
      }
    }

    static let bridgeWaitTimeout: TimeInterval =
      IMsgBridgeProtocol.defaultResponseTimeout + 2

    static func waitForBridgeOperation(
      operation: String,
      timeout: TimeInterval = bridgeWaitTimeout,
      invoke: @escaping @Sendable () async throws -> Void
    ) throws {
      let semaphore = DispatchSemaphore(value: 0)
      let box = BridgeResultBox()
      let task = Task { @Sendable in
        do {
          try await invoke()
        } catch {
          box.setError(error)
        }
        semaphore.signal()
      }
      let boundedTimeout = max(0.01, timeout)
      guard semaphore.wait(timeout: .now() + boundedTimeout) == .success else {
        task.cancel()
        throw DeliveryFailure(
          disposition: .stillInFlight,
          transport: .bridgeV2,
          operation: operation,
          detail: "The synchronous typing bridge wait expired; the bridge task was cancelled."
        )
      }
      if let error = box.error {
        throw error
      }
    }

    private static func setTypingDirect(chatIdentifier: String, isTyping: Bool) throws {
      let frameworkPath = "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
      guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
        let error = String(cString: dlerror())
        throw IMsgError.typingIndicatorFailed(
          "Failed to load IMCore framework: \(error)")
      }
      defer { dlclose(handle) }

      try ensureDaemonConnection()
      let chat = try lookupChat(identifier: chatIdentifier)

      let selector = sel_registerName("setLocalUserIsTyping:")
      guard let method = class_getInstanceMethod(object_getClass(chat), selector) else {
        throw IMsgError.typingIndicatorFailed(
          "setLocalUserIsTyping: method not found on IMChat")
      }
      let implementation = method_getImplementation(method)

      typealias SetTypingFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
      let setTypingFunc = unsafeBitCast(implementation, to: SetTypingFunc.self)
      setTypingFunc(chat, selector, isTyping)
    }

    static func typeForDuration(
      chatIdentifier: String,
      duration: TimeInterval,
      startTyping: (String) throws -> Void,
      stopTyping: (String) throws -> Void,
      sleep: (UInt64) async throws -> Void
    ) async throws {
      guard duration >= 0,
        let nanoseconds = UInt64(exactly: (duration * 1_000_000_000).rounded(.towardZero))
      else {
        throw IMsgError.typingIndicatorFailed(
          "Duration must be a finite, non-negative interval representable in nanoseconds")
      }
      try startTyping(chatIdentifier)
      var stopped = false
      defer {
        if !stopped {
          try? stopTyping(chatIdentifier)
        }
      }
      try await sleep(nanoseconds)
      try stopTyping(chatIdentifier)
      stopped = true
    }

    private static func ensureDaemonConnection() throws {
      guard let controllerClass = objc_getClass("IMDaemonController") as? NSObject.Type else {
        throw IMsgError.typingIndicatorFailed("IMDaemonController class not found")
      }

      let sharedSel = sel_registerName("sharedInstance")
      guard controllerClass.responds(to: sharedSel) else {
        throw IMsgError.typingIndicatorFailed("IMDaemonController.sharedInstance not available")
      }

      guard let controller = controllerClass.perform(sharedSel)?.takeUnretainedValue() else {
        throw IMsgError.typingIndicatorFailed("Failed to get IMDaemonController shared instance")
      }

      if hasLiveDaemonConnection(controller) {
        daemonConnectionTracker.lock.lock()
        daemonConnectionTracker.hasAttemptedConnection = true
        daemonConnectionTracker.connectionKnownUnavailable = false
        daemonConnectionTracker.lock.unlock()
        return
      }

      daemonConnectionTracker.lock.lock()
      let shouldAttemptConnection = !daemonConnectionTracker.hasAttemptedConnection
      if shouldAttemptConnection {
        daemonConnectionTracker.hasAttemptedConnection = true
      }
      daemonConnectionTracker.lock.unlock()
      if !shouldAttemptConnection { return }

      let connectSel = sel_registerName("connectToDaemon")
      if controller.responds(to: connectSel) {
        _ = controller.perform(connectSel)
      }

      let maxAttempts = 50
      for _ in 0..<maxAttempts {
        if hasLiveDaemonConnection(controller) {
          daemonConnectionTracker.lock.lock()
          daemonConnectionTracker.connectionKnownUnavailable = false
          daemonConnectionTracker.lock.unlock()
          return
        }
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      }

      if !hasLiveDaemonConnection(controller) {
        daemonConnectionTracker.lock.lock()
        daemonConnectionTracker.connectionKnownUnavailable = true
        daemonConnectionTracker.lock.unlock()
        throw IMsgError.typingIndicatorFailed(
          daemonUnavailableMessage()
        )
      }
    }

    private static func hasLiveDaemonConnection(_ controller: AnyObject) -> Bool {
      let isConnectedSel = sel_registerName("isConnected")
      guard controller.responds(to: isConnectedSel) else { return false }
      guard let value = controller.perform(isConnectedSel)?.takeUnretainedValue() else {
        return false
      }
      if let number = value as? NSNumber {
        return number.boolValue
      }
      return false
    }

    private static func lookupChat(identifier: String) throws -> NSObject {
      guard let registryClass = objc_getClass("IMChatRegistry") as? NSObject.Type else {
        throw IMsgError.typingIndicatorFailed("IMChatRegistry class not found")
      }

      let sharedSel = sel_registerName("sharedInstance")
      guard registryClass.responds(to: sharedSel) else {
        throw IMsgError.typingIndicatorFailed("IMChatRegistry.sharedInstance not available")
      }

      guard let registry = registryClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject
      else {
        throw IMsgError.typingIndicatorFailed("Failed to get IMChatRegistry shared instance")
      }

      let candidates = chatLookupCandidates(for: identifier)

      let guidSel = sel_registerName("existingChatWithGUID:")
      if registry.responds(to: guidSel) {
        for candidate in candidates {
          if let chat = registry.perform(guidSel, with: candidate)?.takeUnretainedValue()
            as? NSObject
          {
            return chat
          }
        }
      }

      let identSel = sel_registerName("existingChatWithChatIdentifier:")
      if registry.responds(to: identSel) {
        for candidate in candidates {
          if let chat = registry.perform(identSel, with: candidate)?.takeUnretainedValue()
            as? NSObject
          {
            return chat
          }
        }
      }

      daemonConnectionTracker.lock.lock()
      let connectionKnownUnavailable = daemonConnectionTracker.connectionKnownUnavailable
      daemonConnectionTracker.lock.unlock()
      if connectionKnownUnavailable {
        throw IMsgError.typingIndicatorFailed(daemonUnavailableMessage())
      }

      throw IMsgError.typingIndicatorFailed(
        "Chat not found for identifier: \(identifier). "
          + "Make sure Messages.app has an active conversation with this contact.")
    }

    static func daemonUnavailableMessage() -> String {
      "Failed to connect to imagent (Messages daemon) for IMCore typing indicators. "
        + "On macOS 26/Tahoe, imagent can reject third-party clients without "
        + "Apple-private entitlements, and Messages.app may also block the injected "
        + "bridge via library validation. Run 'imsg status' and 'imsg launch' to "
        + "verify advanced feature setup. Normal 'send', 'history', and 'watch' "
        + "commands do not use this IMCore path."
    }

    static func chatLookupCandidates(for identifier: String) -> [String] {
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return [] }

      let bareIdentifier = stripKnownChatPrefix(trimmed) ?? trimmed
      var candidates = [trimmed]
      if bareIdentifier != trimmed {
        candidates.append(bareIdentifier)
      }
      for prefix in chatIdentifierPrefixes {
        candidates.append(prefix + bareIdentifier)
      }
      return dedupe(candidates)
    }

    private static let chatIdentifierPrefixes = [
      "iMessage;-;",
      "iMessage;+;",
      "SMS;-;",
      "SMS;+;",
      "any;-;",
      "any;+;",
    ]

    private static func stripKnownChatPrefix(_ value: String) -> String? {
      for prefix in chatIdentifierPrefixes where value.hasPrefix(prefix) {
        return String(value.dropFirst(prefix.count))
      }
      return nil
    }

    private static func dedupe(_ values: [String]) -> [String] {
      var seen = Set<String>()
      var result: [String] = []
      for value in values where !value.isEmpty {
        if seen.insert(value).inserted {
          result.append(value)
        }
      }
      return result
    }
  }
#else
  /// Non-macOS stub. Linux can read copied databases, but typing indicators
  /// require private IMCore APIs inside Messages.app.
  public struct TypingIndicator: Sendable {
    public static func startTyping(chatIdentifier: String) throws {
      _ = chatIdentifier
      throw unsupported()
    }

    public static func stopTyping(chatIdentifier: String) throws {
      _ = chatIdentifier
      throw unsupported()
    }

    public static func typeForDuration(chatIdentifier: String, duration: TimeInterval) async throws
    {
      _ = chatIdentifier
      _ = duration
      throw unsupported()
    }

    private static func unsupported() -> IMsgError {
      IMsgError.typingIndicatorFailed(
        "Typing indicators require Messages.app/IMCore and are only supported on macOS.")
    }
  }
#endif

#if os(macOS)
  private final class DaemonConnectionTracker: @unchecked Sendable {
    let lock = NSLock()
    var hasAttemptedConnection = false
    var connectionKnownUnavailable = false
  }

  /// Thread-safe box for passing an error out of a Task back to the calling thread.
  private final class BridgeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?

    var error: Error? {
      lock.lock()
      defer { lock.unlock() }
      return _error
    }

    func setError(_ error: Error) {
      lock.lock()
      _error = error
      lock.unlock()
    }
  }
#endif
