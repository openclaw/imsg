import Foundation

#if os(macOS)
  import Darwin
#endif

public struct IMsgEventTailerOverflowError: Error, Sendable, Equatable {}

public enum IMsgEventTailerError: Error, Sendable, Equatable, LocalizedError {
  case invalidBufferLimit(Int)
  case alreadyStarted
  case createFailed(path: String, errno: Int32)
  case openFailed(path: String, errno: Int32)
  case readFailed(path: String, errno: Int32)
  case unsupportedPlatform

  public var errorDescription: String? {
    switch self {
    case .invalidBufferLimit(let limit):
      return "Event buffer limit \(limit) is outside the supported range 1...4096."
    case .alreadyStarted:
      return "This bridge event tailer has already started."
    case .createFailed(let path, let code):
      return "Could not create private bridge event log at \(path) (errno \(code))."
    case .openFailed(let path, let code):
      return "Could not open bridge event log at \(path) (errno \(code))."
    case .readFailed(let path, let code):
      return "Could not read bridge event log at \(path) (errno \(code))."
    case .unsupportedPlatform:
      return "Bridge events are only available on macOS."
    }
  }
}

/// Live, bounded tailer for `.imsg-events.jsonl` written by the injected helper.
///
/// Initial startup begins at EOF unless replay is explicitly requested. Rotation
/// drains the old inode and opens the replacement at offset zero, preserving
/// per-log order without claiming ordering relative to database watch events.
public final class IMsgEventTailer: @unchecked Sendable {
  public struct Event: Sendable {
    public let timestamp: String?
    public let name: String
    public let payloadJSON: Data

    public init(timestamp: String?, name: String, payloadJSON: Data) {
      self.timestamp = timestamp
      self.name = name
      self.payloadJSON = payloadJSON
    }

    public func decodedPayload() -> [String: Any] {
      guard
        let object = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any]
      else { return [:] }
      return object
    }
  }

  private let path: String
  private let replayExisting: Bool
  private let createIfMissing: Bool
  private let bufferLimit: Int
  private let didStart: (@Sendable () -> Void)?
  private let didStop: @Sendable () -> Void
  private let queue = DispatchQueue(label: "imsg.event.tailer", qos: .userInitiated)
  private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
  private var started = false
  private var stopped = false

  #if os(macOS)
    private struct FileIdentity: Equatable {
      let device: UInt64
      let inode: UInt64
    }

    private struct FileRegistration {
      let fd: Int32
      let identity: FileIdentity
      let source: DispatchSourceFileSystemObject
    }

    private var fileRegistration: FileRegistration?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending = Data()
  #endif

  public convenience init(path: String, replayExisting: Bool = false) {
    self.init(path: path, replayExisting: replayExisting, createIfMissing: true)
  }

  public convenience init(
    path: String,
    replayExisting: Bool = false,
    createIfMissing: Bool
  ) {
    self.init(
      uncheckedPath: path,
      replayExisting: replayExisting,
      createIfMissing: createIfMissing,
      bufferLimit: 256,
      didStart: nil,
      didStop: {}
    )
  }

  public convenience init(
    path: String,
    replayExisting: Bool = false,
    bufferLimit: Int,
    createIfMissing: Bool = false
  ) throws {
    guard (1...4096).contains(bufferLimit) else {
      throw IMsgEventTailerError.invalidBufferLimit(bufferLimit)
    }
    self.init(
      uncheckedPath: path,
      replayExisting: replayExisting,
      createIfMissing: createIfMissing,
      bufferLimit: bufferLimit,
      didStart: nil,
      didStop: {})
  }

  private init(
    uncheckedPath path: String,
    replayExisting: Bool,
    createIfMissing: Bool,
    bufferLimit: Int,
    didStart: (@Sendable () -> Void)?,
    didStop: @escaping @Sendable () -> Void
  ) {
    self.path = path
    self.replayExisting = replayExisting
    self.createIfMissing = createIfMissing
    self.bufferLimit = bufferLimit
    self.didStart = didStart
    self.didStop = didStop
  }

  /// Starts one event stream. The first event rejected by the bounded buffer
  /// stops the file sources; accepted events drain before the overflow error.
  public func events() -> AsyncThrowingStream<Event, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(bufferLimit)) { continuation in
      queue.async {
        guard !self.started else {
          continuation.finish(throwing: IMsgEventTailerError.alreadyStarted)
          return
        }
        guard !self.stopped else {
          continuation.finish()
          return
        }
        self.started = true
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
          self.stop()
        }
        #if os(macOS)
          self.startMacOS()
        #else
          self.finish(throwing: IMsgEventTailerError.unsupportedPlatform)
        #endif
      }
    }
  }

  public func stop() {
    queue.async {
      self.finish()
    }
  }

  private func finish(throwing error: Error? = nil) {
    guard !stopped else { return }
    stopped = true
    let activeContinuation = continuation
    continuation = nil
    #if os(macOS)
      fileRegistration?.source.cancel()
      fileRegistration = nil
      directorySource?.cancel()
      directorySource = nil
    #endif
    if let error {
      activeContinuation?.finish(throwing: error)
    } else {
      activeContinuation?.finish()
    }
    didStop()
  }

  #if os(macOS)
    private func startMacOS() {
      do {
        try createInitialFileIfNeeded()
        try installDirectorySource()
        try openInitialFile()
        guard !stopped else { return }
        didStart?()
      } catch {
        finish(throwing: error)
      }
    }

    private func openInitialFile() throws {
      let registration = try makeFileRegistration()
      if !replayExisting, lseek(registration.fd, 0, SEEK_END) < 0 {
        let code = errno
        registration.source.cancel()
        throw IMsgEventTailerError.readFailed(path: path, errno: code)
      }
      fileRegistration = registration
      try drainAvailable()
      reconcileCurrentPath()
    }

    private func makeFileRegistration() throws -> FileRegistration {
      let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else {
        throw IMsgEventTailerError.openFailed(path: path, errno: errno)
      }
      var info = stat()
      guard fstat(fd, &info) == 0 else {
        let code = errno
        close(fd)
        throw IMsgEventTailerError.openFailed(path: path, errno: code)
      }
      guard (info.st_mode & S_IFMT) == S_IFREG else {
        close(fd)
        throw IMsgEventTailerError.openFailed(path: path, errno: EINVAL)
      }
      let identity = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.extend, .write, .rename, .delete],
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.handleFileEvent()
      }
      source.setCancelHandler {
        close(fd)
      }
      source.resume()
      return FileRegistration(fd: fd, identity: identity, source: source)
    }

    private func handleFileEvent() {
      guard !stopped, let registration = fileRegistration else { return }
      let events = registration.source.data
      do {
        try drainAvailable()
      } catch {
        finish(throwing: error)
        return
      }
      if events.contains(.delete), !events.contains(.rename) {
        do {
          if try currentPathIdentity() == nil {
            finish(throwing: IMsgEventTailerError.openFailed(path: path, errno: ENOENT))
            return
          }
        } catch {
          finish(throwing: error)
          return
        }
      }
      reconcileCurrentPath()
    }

    private func reconcileCurrentPath() {
      do {
        guard !stopped, let current = fileRegistration else { return }
        guard let pathIdentity = try currentPathIdentity() else {
          // A rename and replacement are two syscalls. The directory source owns
          // the gap and calls back as soon as the new path is created.
          return
        }
        guard pathIdentity != current.identity else { return }
        try drainAvailable()
        let replacement = try makeFileRegistration()
        guard replacement.identity == pathIdentity else {
          replacement.source.cancel()
          reconcileCurrentPath()
          return
        }
        pending.removeAll(keepingCapacity: true)
        fileRegistration = replacement
        current.source.cancel()
        try drainAvailable()
        reconcileCurrentPath()
      } catch {
        finish(throwing: error)
      }
    }

    private func currentPathIdentity() throws -> FileIdentity? {
      var info = stat()
      guard lstat(path, &info) == 0 else {
        if errno == ENOENT { return nil }
        throw IMsgEventTailerError.openFailed(path: path, errno: errno)
      }
      guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw IMsgEventTailerError.openFailed(path: path, errno: EINVAL)
      }
      return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func drainAvailable() throws {
      guard let registration = fileRegistration else { return }
      var bytes = [UInt8](repeating: 0, count: 8192)
      while true {
        let count = read(registration.fd, &bytes, bytes.count)
        if count > 0 {
          pending.append(bytes, count: count)
          processPending()
          if stopped { return }
          continue
        }
        if count == 0 { return }
        if errno == EINTR { continue }
        throw IMsgEventTailerError.readFailed(path: path, errno: errno)
      }
    }

    private func processPending() {
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[..<newline]
        pending.removeSubrange(...newline)
        guard !line.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { continue }
        let name = object["event"] as? String ?? "unknown"
        let timestamp = object["ts"] as? String
        let payload = object["data"] as? [String: Any] ?? [:]
        let payloadJSON =
          (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        let event = Event(timestamp: timestamp, name: name, payloadJSON: payloadJSON)
        switch continuation?.yield(event) {
        case .enqueued:
          continue
        case .dropped:
          finish(throwing: IMsgEventTailerOverflowError())
          return
        case .terminated, .none:
          finish()
          return
        @unknown default:
          finish()
          return
        }
      }
    }
  #endif
}

#if os(macOS)
  extension IMsgEventTailer {
    fileprivate func createInitialFileIfNeeded() throws {
      guard createIfMissing else { return }
      let fd = open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
      guard fd >= 0 else {
        // The helper may have won the creation race. The normal secure open
        // below validates whatever now owns the path.
        if errno == EEXIST { return }
        throw IMsgEventTailerError.createFailed(path: path, errno: errno)
      }
      defer { close(fd) }

      var info = stat()
      guard fstat(fd, &info) == 0 else {
        throw IMsgEventTailerError.createFailed(path: path, errno: errno)
      }
      guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw IMsgEventTailerError.createFailed(path: path, errno: EINVAL)
      }
      guard fchmod(fd, 0o600) == 0 else {
        throw IMsgEventTailerError.createFailed(path: path, errno: errno)
      }
    }

    fileprivate func installDirectorySource() throws {
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
      let fd = open(directory, O_EVTONLY | O_CLOEXEC)
      guard fd >= 0 else {
        throw IMsgEventTailerError.openFailed(path: directory, errno: errno)
      }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .rename, .delete],
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.reconcileCurrentPath()
      }
      source.setCancelHandler {
        close(fd)
      }
      source.resume()
      directorySource = source
    }
  }
#endif

extension IMsgEventTailer {
  convenience init(
    path: String,
    replayExisting: Bool = false,
    bufferLimit: Int = 256,
    createIfMissing: Bool = false,
    didStart: (@Sendable () -> Void)? = nil,
    didStop: @escaping @Sendable () -> Void
  ) throws {
    guard (1...4096).contains(bufferLimit) else {
      throw IMsgEventTailerError.invalidBufferLimit(bufferLimit)
    }
    self.init(
      uncheckedPath: path,
      replayExisting: replayExisting,
      createIfMissing: createIfMissing,
      bufferLimit: bufferLimit,
      didStart: didStart,
      didStop: didStop
    )
  }
}
