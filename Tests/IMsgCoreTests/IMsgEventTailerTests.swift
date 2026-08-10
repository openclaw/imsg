import Foundation
import Testing

@testable import IMsgCore

#if os(macOS)
  import Darwin
#endif

@Suite("IMsgEventTailer")
struct IMsgEventTailerTests {
  @Test(.timeLimit(.minutes(1)))
  func initialEOFSkipsExistingAndAppendOrderIsStable() async throws {
    try await withEventFile(existing: ["old"]) { path in
      let started = CallbackProbe()
      let tailer = try IMsgEventTailer(
        path: path,
        didStart: { Task { await started.record() } },
        didStop: {})
      let stream = tailer.events()
      await started.wait()

      try appendEvents(["first", "second"], to: path)
      var iterator = stream.makeAsyncIterator()
      #expect(try await iterator.next()?.name == "first")
      #expect(try await iterator.next()?.name == "second")
      tailer.stop()
      let startCount = await started.callCount()
      #expect(startCount == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rotationIncludesTriggerAndImmediateNextEventExactlyOnce() async throws {
    try await withEventFile { path in
      let started = CallbackProbe()
      let tailer = try IMsgEventTailer(
        path: path,
        didStart: { Task { await started.record() } },
        didStop: {})
      let stream = tailer.events()
      await started.wait()

      try appendEvents(["before-rotation"], to: path)
      let rotated = path + ".1"
      try FileManager.default.moveItem(atPath: path, toPath: rotated)
      try eventLine("rotation-trigger").write(
        to: URL(fileURLWithPath: path), atomically: false, encoding: .utf8)
      try appendEvents(["immediate-next"], to: path)

      var names: [String] = []
      for try await event in stream {
        names.append(event.name)
        if names.count == 3 { break }
      }
      #expect(names == ["before-rotation", "rotation-trigger", "immediate-next"])
      tailer.stop()
    }
  }

  @Test
  func missingPathCanBeCreatedPrivatelyAndReceiveLaterAppend() async throws {
    let directory = NSTemporaryDirectory() + "/imsg-tailer-create-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = (directory as NSString).appendingPathComponent("events.jsonl")
    let started = CallbackProbe()
    let tailer = try IMsgEventTailer(
      path: path,
      createIfMissing: true,
      didStart: { Task { await started.record() } },
      didStop: {})
    let stream = tailer.events()
    await started.wait()

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try appendEvents(["late-append"], to: path)
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next()?.name == "late-append")
    tailer.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func missingPathFinishesWithOpenFailure() async throws {
    let path = NSTemporaryDirectory() + "/missing-event-log-\(UUID().uuidString)"
    let started = CallbackProbe()
    let tailer = try IMsgEventTailer(
      path: path,
      didStart: { Task { await started.record() } },
      didStop: {})
    var iterator = tailer.events().makeAsyncIterator()
    do {
      _ = try await iterator.next()
      Issue.record("expected open failure")
    } catch let error as IMsgEventTailerError {
      guard case .openFailed(let failedPath, _) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(failedPath == path)
    }
    let startCount = await started.callCount()
    #expect(startCount == 0)
  }

  @Test
  func createIfMissingRejectsSymlinkWithoutMutatingTarget() async throws {
    let directory = NSTemporaryDirectory() + "/imsg-tailer-symlink-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let target = (directory as NSString).appendingPathComponent("target")
    let path = (directory as NSString).appendingPathComponent("events.jsonl")
    try Data("unchanged".utf8).write(to: URL(fileURLWithPath: target))
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

    let tailer = IMsgEventTailer(path: path, createIfMissing: true)
    var iterator = tailer.events().makeAsyncIterator()
    do {
      _ = try await iterator.next()
      Issue.record("expected symlink open failure")
    } catch let error as IMsgEventTailerError {
      guard case .openFailed(let failedPath, _) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(failedPath == path)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("unchanged".utf8))
  }

  @Test(.timeLimit(.minutes(1)))
  func fifoPathIsRejectedWithoutBlocking() async throws {
    let directory = NSTemporaryDirectory() + "/imsg-tailer-fifo-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = (directory as NSString).appendingPathComponent("events.jsonl")
    #expect(mkfifo(path, 0o600) == 0)

    let tailer = IMsgEventTailer(path: path, createIfMissing: false)
    var iterator = tailer.events().makeAsyncIterator()
    do {
      _ = try await iterator.next()
      Issue.record("expected FIFO rejection")
    } catch let error as IMsgEventTailerError {
      guard case .openFailed(let failedPath, let code) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(failedPath == path)
      #expect(code == EINVAL)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func directorySourceFinishesWithOpenFailure() async throws {
    let directory = NSTemporaryDirectory() + "/imsg-event-directory-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let started = CallbackProbe()
    let tailer = try IMsgEventTailer(
      path: directory,
      replayExisting: true,
      didStart: { Task { await started.record() } },
      didStop: {})
    var iterator = tailer.events().makeAsyncIterator()
    do {
      _ = try await iterator.next()
      Issue.record("expected nonregular source rejection")
    } catch let error as IMsgEventTailerError {
      guard case .openFailed(let failedPath, let code) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(failedPath == directory)
      #expect(code == EINVAL)
    }
    let startCount = await started.callCount()
    #expect(startCount == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func bufferOneDrainsAcceptedEventThenThrowsOverflowAndStops() async throws {
    try await withEventFile(existing: ["accepted", "rejected"]) { path in
      let stopped = CallbackProbe()
      let tailer = try IMsgEventTailer(
        path: path,
        replayExisting: true,
        bufferLimit: 1,
        didStop: { Task { await stopped.record() } }
      )
      let stream = tailer.events()
      await stopped.wait()
      var iterator = stream.makeAsyncIterator()
      #expect(try await iterator.next()?.name == "accepted")
      do {
        _ = try await iterator.next()
        Issue.record("expected overflow")
      } catch is IMsgEventTailerOverflowError {
        // Accepted events drain before the typed terminal overflow.
      }
      let stopCount = await stopped.callCount()
      #expect(stopCount == 1)
    }
  }

  @Test
  func rejectsInvalidBufferLimits() {
    for limit in [0, 4097] {
      #expect(throws: IMsgEventTailerError.self) {
        _ = try IMsgEventTailer(path: "/tmp/events", bufferLimit: limit)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func completedTailerReleasesOwner() async throws {
    weak var releasedTailer: IMsgEventTailer?
    try await withEventFile { path in
      let started = CallbackProbe()
      let stopped = CallbackProbe()
      var tailer: IMsgEventTailer? = try IMsgEventTailer(
        path: path,
        didStart: { Task { await started.record() } },
        didStop: { Task { await stopped.record() } }
      )
      releasedTailer = tailer
      var stream: AsyncThrowingStream<IMsgEventTailer.Event, Error>? = tailer?.events()
      await started.wait()
      tailer?.stop()
      await stopped.wait()
      do {
        var iterator = try #require(stream?.makeAsyncIterator())
        #expect(try await iterator.next()?.name == nil)
      }
      stream = nil
      tailer = nil
    }
    #expect(releasedTailer == nil)
  }

  @Test
  func eventDecodedPayloadRoundTrip() throws {
    let raw: [String: Any] = ["chatGuid": "iMessage;-;+1", "extra": 42]
    let data = try JSONSerialization.data(withJSONObject: raw)
    let event = IMsgEventTailer.Event(timestamp: nil, name: "x", payloadJSON: data)
    #expect(event.decodedPayload()["chatGuid"] as? String == "iMessage;-;+1")
    #expect(event.decodedPayload()["extra"] as? Int == 42)
  }

  private func withEventFile(
    existing: [String] = [],
    operation: (String) async throws -> Void
  ) async throws {
    let directory = NSTemporaryDirectory() + "/imsg-tailer-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = (directory as NSString).appendingPathComponent("events.jsonl")
    try existing.map(eventLine).joined().write(
      to: URL(fileURLWithPath: path), atomically: false, encoding: .utf8)
    try await operation(path)
  }

  private func appendEvents(_ names: [String], to path: String) throws {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(names.map(eventLine).joined().utf8))
    try handle.synchronize()
  }

  private func eventLine(_ name: String) -> String {
    "{\"event\":\"\(name)\",\"data\":{\"sequence\":\"\(name)\"}}\n"
  }

}

private actor CallbackProbe {
  private var count = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func record() {
    count += 1
    guard count == 1 else { return }
    let pendingWaiters = waiters
    waiters.removeAll()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }

  func wait() async {
    if count > 0 { return }
    await withCheckedContinuation { continuation in
      if count > 0 {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func callCount() -> Int {
    count
  }
}
