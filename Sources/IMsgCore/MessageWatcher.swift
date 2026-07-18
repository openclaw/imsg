import Foundation

#if os(macOS)
  import Darwin
#endif

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var fallbackPollInterval: TimeInterval?
  /// Holds newly observed rows briefly because Messages can commit a linked
  /// URL-preview row after its text row in a separate filesystem event.
  public var urlPreviewSettleInterval: TimeInterval
  public var batchLimit: Int
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    fallbackPollInterval: TimeInterval? = 5,
    urlPreviewSettleInterval: TimeInterval = 2,
    batchLimit: Int = 100,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.fallbackPollInterval = fallbackPollInterval
    self.urlPreviewSettleInterval = urlPreviewSettleInterval
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
  private var startupTailRowID: Int64 = 0
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
  private var settleUntil: Date?
  private var settleMaxTextRowID: Int64?

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
        let tailRowID = try self.store.maxRowID()
        if self.cursor == 0 {
          self.cursor = tailRowID
        }
        self.startupTailRowID = tailRowID
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
      let queryLimit =
        configuration.batchLimit == Int.max
        ? Int.max : configuration.batchLimit + 1
      let batch = try store.messagesAfterBatch(
        afterRowID: cursor,
        chatID: chatID,
        limit: queryLimit,
        includeReactions: configuration.includeReactions,
        suppressLateURLPreviews: false,
        deduplicateURLBalloons: false
      )
      if shouldWaitForURLPreviewCompanion(
        messages: batch.messages,
        maxScannedRowID: batch.maxScannedRowID
      ) {
        return
      }
      for message in batch.messages {
        switch yieldDecision(for: message) {
        case .yield:
          break
        case .retry:
          return
        case .skip:
          continue
        }
        if store.isURLPreviewBalloon(message),
          store.shouldSkipURLBalloonDuplicate(
            chatID: message.chatID,
            sender: message.sender,
            text: message.text,
            isFromMe: message.isFromMe,
            date: message.date,
            rowID: message.rowID
          )
        {
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
      clearURLPreviewSettleState()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func shouldWaitForURLPreviewCompanion(
    messages: [Message],
    maxScannedRowID: Int64
  ) -> Bool {
    let interval = configuration.urlPreviewSettleInterval
    guard interval > 0, maxScannedRowID > cursor else {
      return false
    }
    // A preview-only batch is already the companion row. Emit it now; querying
    // it twice would also feed the stateful URL-balloon dedupe cache twice.
    let hasLiveTextRow = messages.contains {
      $0.rowID > startupTailRowID && !store.isURLPreviewBalloon($0)
    }
    guard settleUntil != nil || hasLiveTextRow else { return false }

    let uncoalescedLiveTextRows = messages.filter {
      $0.rowID > startupTailRowID && !store.isURLPreviewBalloon($0) && $0.urlPreview == nil
    }
    if settleUntil != nil, uncoalescedLiveTextRows.isEmpty {
      return false
    }

    let now = Date()
    let newestUncoalescedTextRowID = uncoalescedLiveTextRows.map(\.rowID).max()
    if let newestUncoalescedTextRowID,
      settleMaxTextRowID == nil || newestUncoalescedTextRowID > (settleMaxTextRowID ?? 0)
    {
      let deadline = now.addingTimeInterval(interval)
      settleMaxTextRowID = newestUncoalescedTextRowID
      settleUntil = deadline
      scheduleURLPreviewSettlePoll(at: deadline)
    }

    guard let settleUntil, now < settleUntil else { return false }
    return true
  }

  private func scheduleURLPreviewSettlePoll(at date: Date) {
    let delay = max(0, date.timeIntervalSinceNow)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, !self.stopped else { return }
      self.poll()
    }
  }

  private func clearURLPreviewSettleState() {
    settleUntil = nil
    settleMaxTextRowID = nil
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
