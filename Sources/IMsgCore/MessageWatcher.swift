import Foundation

#if os(macOS)
  import Darwin
#endif

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var fallbackPollInterval: TimeInterval?
  public var batchLimit: Int
  public var bufferLimit: Int {
    didSet {
      bufferLimit = Self.clampBufferLimit(bufferLimit)
    }
  }
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    fallbackPollInterval: TimeInterval? = 5,
    batchLimit: Int = 100,
    bufferLimit: Int = 256,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.fallbackPollInterval = fallbackPollInterval
    self.batchLimit = batchLimit
    self.bufferLimit = Self.clampBufferLimit(bufferLimit)
    self.includeReactions = includeReactions
  }

  private static func clampBufferLimit(_ value: Int) -> Int {
    min(max(value, 1), 4096)
  }
}

public struct MessageWatcherOverflowError: Error, Sendable, Equatable {
  public let resumeAfterRowID: Int64

  public init(resumeAfterRowID: Int64) {
    self.resumeAfterRowID = resumeAfterRowID
  }
}

public final class MessageWatcher: @unchecked Sendable {
  private let store: MessageStore
  private let didPoll: @Sendable () -> Void

  public init(store: MessageStore) {
    self.store = store
    self.didPoll = {}
  }

  init(store: MessageStore, didPoll: @escaping @Sendable () -> Void) {
    self.store = store
    self.didPoll = didPoll
  }

  public func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration(),
    filter: MessageFilter = MessageFilter()
  ) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(configuration.bufferLimit)) {
      continuation in
      let state = WatchState(
        store: store,
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        filter: filter,
        didPoll: didPoll,
        continuation: continuation
      )
      state.start()
      continuation.onTermination = { _ in
        state.stop()
      }
    }
  }
}

private final class WatchState: @unchecked Sendable {
  private static let unresolvedChatRetryLimit = 20

  private enum MessageYieldDecision {
    case yield
    case retry
    case skip
  }

  private let store: MessageStore
  private let chatID: Int64?
  private let configuration: MessageWatcherConfiguration
  private let filter: MessageFilter
  private let didPoll: @Sendable () -> Void
  private let continuation: AsyncThrowingStream<Message, Error>.Continuation
  private let queue = DispatchQueue(label: "imsg.watch", qos: .userInitiated)

  private var cursor: Int64
  private var resumeAfterRowID: Int64
  private var urlBalloonDedupe = URLBalloonDedupeState()
  #if os(macOS)
    private struct FileWatchIdentity: Equatable {
      let device: UInt64
      let inode: UInt64
    }

    private struct FileWatchRegistration {
      let source: DispatchSourceFileSystemObject
      let identity: FileWatchIdentity
    }

    private var fileSources: [String: FileWatchRegistration] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
  #endif
  private var pending = false
  private var stopped = false
  private var unresolvedChatAttempts: [Int64: Int] = [:]

  init(
    store: MessageStore,
    chatID: Int64?,
    sinceRowID: Int64?,
    configuration: MessageWatcherConfiguration,
    filter: MessageFilter,
    didPoll: @escaping @Sendable () -> Void,
    continuation: AsyncThrowingStream<Message, Error>.Continuation
  ) {
    self.store = store
    self.chatID = chatID
    self.configuration = configuration
    self.filter = filter
    self.didPoll = didPoll
    self.continuation = continuation
    self.cursor = sinceRowID ?? 0
    self.resumeAfterRowID = sinceRowID ?? 0
  }

  func start() {
    queue.async {
      do {
        if self.cursor == 0 {
          self.cursor = try self.store.maxRowID()
          self.resumeAfterRowID = self.cursor
        }
        #if os(macOS)
          self.refreshFileSources()
          self.installDirectorySource()
        #endif
        self.poll()
        self.scheduleFallbackPoll()
      } catch {
        self.finish(throwing: error)
      }
    }
  }

  func stop() {
    queue.async {
      self.stopSources()
    }
  }

  #if os(macOS)
    private var watchedFilePaths: [String] {
      [store.path, store.path + "-wal", store.path + "-shm"]
    }

    private var watchDirectoryPath: String? {
      guard store.path.hasPrefix("/") else { return nil }
      let directoryPath = URL(fileURLWithPath: store.path).deletingLastPathComponent().path
      var isDirectory: ObjCBool = false
      guard
        !directoryPath.isEmpty,
        FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        return nil
      }
      return directoryPath
    }

    private func refreshFileSources() {
      if stopped { return }

      for path in watchedFilePaths {
        guard let currentIdentity = fileIdentity(path: path) else {
          if let registration = fileSources.removeValue(forKey: path) {
            registration.source.cancel()
          }
          continue
        }

        if let registration = fileSources[path] {
          if registration.identity == currentIdentity {
            continue
          }
          registration.source.cancel()
          fileSources[path] = nil
        }

        if let source = makeSource(path: path) {
          fileSources[path] = FileWatchRegistration(source: source, identity: currentIdentity)
        }
      }
    }

    private func installDirectorySource() {
      guard directorySource == nil, let path = watchDirectoryPath else { return }
      guard let source = makeSource(path: path) else { return }
      directorySource = source
    }

    private func fileIdentity(path: String) -> FileWatchIdentity? {
      var info = stat()
      guard stat(path, &info) == 0 else { return nil }
      return FileWatchIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
      let fd = open(path, O_EVTONLY)
      guard fd >= 0 else { return nil }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .rename, .delete],
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.refreshFileSources()
        self?.schedulePoll()
      }
      source.setCancelHandler {
        close(fd)
      }
      source.resume()
      return source
    }
  #endif

  private func schedulePoll() {
    if stopped { return }
    if pending { return }
    pending = true
    let delay = configuration.debounceInterval
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      if self.stopped { return }
      self.pending = false
      self.poll()
    }
  }

  private func scheduleFallbackPoll() {
    guard let interval = configuration.fallbackPollInterval, interval > 0 else { return }
    queue.asyncAfter(deadline: .now() + interval) { [weak self] in
      guard let self, !self.stopped else { return }
      #if os(macOS)
        self.refreshFileSources()
      #endif
      self.poll()
      self.scheduleFallbackPoll()
    }
  }

  private func poll() {
    if stopped { return }
    defer { didPoll() }
    do {
      let previousCursor = cursor
      let batch = try store.messagesAfterBatch(
        afterRowID: cursor,
        chatID: chatID,
        limit: configuration.batchLimit,
        includeReactions: configuration.includeReactions
      )
      for message in batch.messages {
        switch yieldDecision(for: message) {
        case .yield:
          break
        case .retry:
          return
        case .skip:
          continue
        }
        cursor = max(cursor, message.rowID)
        // Commit dedupe only for rows reached after chat resolution; later rows must survive retries.
        if store.isURLPreviewBalloon(message), urlBalloonDedupe.shouldSkip(message) { continue }
        guard filter.allows(message) else { continue }
        switch continuation.yield(message) {
        case .enqueued:
          // This is the last cursor guaranteed to reach the consumer if a later yield overflows.
          resumeAfterRowID = message.rowID
        case .dropped:
          finish(throwing: MessageWatcherOverflowError(resumeAfterRowID: resumeAfterRowID))
          return
        case .terminated:
          stopSources()
          return
        @unknown default:
          stopSources()
          return
        }
      }
      cursor = max(cursor, batch.maxScannedRowID)
      if cursor > previousCursor {
        // Drain in bounded turns so cancellation can run without waiting for the fallback timer.
        queue.async { self.poll() }
      }
    } catch {
      finish(throwing: error)
    }
  }

  private func finish(throwing error: Error) {
    stopSources()
    continuation.finish(throwing: error)
  }

  private func stopSources() {
    guard !stopped else { return }
    stopped = true
    #if os(macOS)
      for registration in fileSources.values {
        registration.source.cancel()
      }
      fileSources.removeAll()
      directorySource?.cancel()
      directorySource = nil
    #endif
  }

  private func yieldDecision(for message: Message) -> MessageYieldDecision {
    guard message.chatID <= 0 else {
      unresolvedChatAttempts.removeValue(forKey: message.rowID)
      return .yield
    }

    let attempts = (unresolvedChatAttempts[message.rowID] ?? 0) + 1
    unresolvedChatAttempts[message.rowID] = attempts
    if attempts <= Self.unresolvedChatRetryLimit {
      schedulePoll()
      return .retry
    }

    unresolvedChatAttempts.removeValue(forKey: message.rowID)
    if message.rowID > cursor {
      cursor = message.rowID
    }
    return .skip
  }
}
