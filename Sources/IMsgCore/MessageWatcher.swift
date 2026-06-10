import Foundation

#if os(macOS)
  import Darwin
#endif

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var fallbackPollInterval: TimeInterval?
  public var batchLimit: Int
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    fallbackPollInterval: TimeInterval? = 5,
    batchLimit: Int = 100,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.fallbackPollInterval = fallbackPollInterval
    self.batchLimit = batchLimit
    self.includeReactions = includeReactions
  }
}

public final class MessageWatcher: @unchecked Sendable {
  private let store: MessageStore

  public init(store: MessageStore) {
    self.store = store
  }

  public func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
      let state = WatchState(
        store: store,
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
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
  private let continuation: AsyncThrowingStream<Message, Error>.Continuation
  private let queue = DispatchQueue(label: "imsg.watch", qos: .userInitiated)

  private var cursor: Int64
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
    continuation: AsyncThrowingStream<Message, Error>.Continuation
  ) {
    self.store = store
    self.chatID = chatID
    self.configuration = configuration
    self.continuation = continuation
    self.cursor = sinceRowID ?? 0
  }

  func start() {
    queue.async {
      do {
        if self.cursor == 0 {
          self.cursor = try self.store.maxRowID()
        }
        #if os(macOS)
          self.refreshFileSources()
          self.installDirectorySource()
        #endif
        self.poll()
        self.scheduleFallbackPoll()
      } catch {
        self.continuation.finish(throwing: error)
      }
    }
  }

  func stop() {
    queue.async {
      self.stopped = true
      #if os(macOS)
        for registration in self.fileSources.values {
          registration.source.cancel()
        }
        self.fileSources.removeAll()
        self.directorySource?.cancel()
        self.directorySource = nil
      #endif
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
    do {
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
        continuation.yield(message)
        if message.rowID > cursor {
          cursor = message.rowID
        }
      }
      if batch.maxScannedRowID > cursor {
        cursor = batch.maxScannedRowID
      }
    } catch {
      continuation.finish(throwing: error)
    }
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
