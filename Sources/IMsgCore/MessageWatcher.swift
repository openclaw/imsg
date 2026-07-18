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

  fileprivate enum MessageYieldDecision {
    case yield
    case retry
    case skip
  }

  private struct URLPreviewSettleCohort {
    let throughRowID: Int64
    let deadline: Date
  }

  fileprivate struct URLPreviewDeliveryKey: Hashable {
    let rowID: Int64
    let chatID: Int64
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
  private var terminallySkippedRowIDs = Set<Int64>()
  private var urlPreviewSettleCohorts: [URLPreviewSettleCohort] = []
  private var deliveredURLPreviews = Set<URLPreviewDeliveryKey>()

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
    do {
      // Capture the tail before returning the stream. Otherwise a message can
      // arrive between subscription and asynchronous startup, be mistaken for
      // pre-existing history, and bypass the URL-preview settle window.
      let tailRowID = try store.maxRowID()
      queue.async {
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
      }
    } catch {
      continuation.finish(throwing: error)
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
      let observedTailRowID = try store.maxRowID(
        chatID: chatID,
        includeReactions: configuration.includeReactions
      )
      registerURLPreviewSettleCohort(
        throughRowID: max(observedTailRowID, batch.maxScannedRowID),
        observedAt: Date()
      )
      let settlingTextRowID = urlPreviewSettlingBoundary(messages: batch.messages)
      let firstHeldRowID = settlingTextRowID.flatMap { boundary in
        batch.messages
          .filter { $0.physicalCompletionRowID >= boundary }
          .map(\.rowID)
          .min()
      }
      let messagesToDeliver = batch.messages
        .filter { message in
          guard let settlingTextRowID else { return true }
          guard message.physicalCompletionRowID < settlingTextRowID else { return false }
          guard let firstHeldRowID else { return false }
          return message.rowID < firstHeldRowID
        }
        .sorted { lhs, rhs in
          if lhs.physicalCompletionRowID == rhs.physicalCompletionRowID {
            return lhs.rowID < rhs.rowID
          }
          return lhs.physicalCompletionRowID < rhs.physicalCompletionRowID
        }
      var deliverableMessages: [Message] = []
      var pendingURLPreviews = deliveredURLPreviews
      for message in messagesToDeliver {
        switch yieldDecision(for: message) {
        case .yield:
          break
        case .retry:
          // Abort before any yield or cursor update so this unresolved row
          // remains inside both the internal and published frontiers.
          return
        case .skip:
          continue
        }
        let urlPreviewKey = urlPreviewDeliveryKey(for: message)
        if let urlPreviewKey, deliveredURLPreviews.contains(urlPreviewKey) {
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
        if let urlPreviewKey, !pendingURLPreviews.insert(urlPreviewKey).inserted {
          continue
        }
        deliverableMessages.append(message)
      }

      var eventCursors = Array(repeating: cursor, count: deliverableMessages.count)
      var nextUndeliveredRowID = firstHeldRowID
      for index in deliverableMessages.indices.reversed() {
        if let nextUndeliveredRowID {
          eventCursors[index] = max(cursor, nextUndeliveredRowID - 1)
        } else {
          eventCursors[index] = max(cursor, batch.maxScannedRowID)
        }
        let rowID = deliverableMessages[index].rowID
        nextUndeliveredRowID = min(nextUndeliveredRowID ?? rowID, rowID)
      }

      for (index, message) in deliverableMessages.enumerated() {
        continuation.yield(message.withCursorRowID(eventCursors[index]))
        if let urlPreviewKey = urlPreviewDeliveryKey(for: message) {
          deliveredURLPreviews.insert(urlPreviewKey)
        }
      }
      if let firstHeldRowID {
        cursor = max(cursor, firstHeldRowID - 1)
      } else if let settlingTextRowID {
        cursor = max(cursor, settlingTextRowID - 1)
      } else if batch.maxScannedRowID > cursor {
        cursor = batch.maxScannedRowID
      }
      pruneURLPreviewSettleState()
    } catch {
      continuation.finish(throwing: error)
    }
  }
}

extension WatchState {
  fileprivate func registerURLPreviewSettleCohort(throughRowID: Int64, observedAt: Date) {
    let interval = configuration.urlPreviewSettleInterval
    guard interval > 0 else { return }
    let coveredThroughRowID = urlPreviewSettleCohorts.last?.throughRowID ?? startupTailRowID
    guard throughRowID > max(startupTailRowID, coveredThroughRowID) else { return }
    urlPreviewSettleCohorts.append(
      URLPreviewSettleCohort(
        throughRowID: throughRowID,
        deadline: observedAt.addingTimeInterval(interval)
      ))
  }

  fileprivate func urlPreviewSettlingBoundary(messages: [Message]) -> Int64? {
    guard configuration.urlPreviewSettleInterval > 0 else {
      return nil
    }

    // Reactions do not create their own settle gap. The poll's firstHeldRowID
    // frontier still keeps every later event behind an earlier pending text.
    let uncoalescedLiveTextRows = messages.filter {
      $0.rowID > startupTailRowID && !$0.isReaction && !store.isURLPreviewBalloon($0)
        && $0.urlPreview == nil
    }

    let now = Date()
    let waitingRows = uncoalescedLiveTextRows.compactMap { message -> (Int64, Date)? in
      guard
        let deadline = urlPreviewSettleCohorts.first(where: {
          message.rowID <= $0.throughRowID
        })?.deadline,
        now < deadline
      else {
        return nil
      }
      return (message.rowID, deadline)
    }
    guard let boundary = waitingRows.min(by: { $0.0 < $1.0 }) else { return nil }
    if let nextDeadline = waitingRows.map(\.1).min() {
      scheduleURLPreviewSettlePoll(at: nextDeadline)
    }
    return boundary.0
  }

  fileprivate func scheduleURLPreviewSettlePoll(at date: Date) {
    let delay = max(0, date.timeIntervalSinceNow)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, !self.stopped else { return }
      self.poll()
    }
  }

  fileprivate func pruneURLPreviewSettleState() {
    urlPreviewSettleCohorts.removeAll { $0.throughRowID <= cursor }
    deliveredURLPreviews = deliveredURLPreviews.filter { $0.rowID > cursor }
    terminallySkippedRowIDs = terminallySkippedRowIDs.filter { $0 > cursor }
  }

  fileprivate func urlPreviewDeliveryKey(for message: Message) -> URLPreviewDeliveryKey? {
    let rowID =
      message.urlPreview?.rowID
      ?? (store.isURLPreviewBalloon(message) ? message.rowID : nil)
    return rowID.map { URLPreviewDeliveryKey(rowID: $0, chatID: message.chatID) }
  }

  fileprivate func yieldDecision(for message: Message) -> MessageYieldDecision {
    if terminallySkippedRowIDs.contains(message.rowID) {
      return .skip
    }
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
    terminallySkippedRowIDs.insert(message.rowID)
    return .skip
  }
}
