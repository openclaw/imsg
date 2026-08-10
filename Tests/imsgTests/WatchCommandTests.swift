import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func singleMessageStreamProvider(
  _ message: Message
) -> (
  MessageWatcher,
  Int64?,
  Int64?,
  MessageWatcherConfiguration,
  MessageFilter
) -> AsyncThrowingStream<Message, Error> {
  return { _, _, _, _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(message)
      continuation.finish()
    }
  }
}

@Test
func watchCommandRejectsInvalidDebounce() async {
  let values = ParsedValues(
    positional: [],
    options: ["debounce": ["nope"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    _ = try await StdoutCapture.capture {
      try await WatchCommand.spec.run(values, runtime)
    }
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Invalid value"))
  } catch {
    #expect(Bool(false))
  }
}

@Test(arguments: ["-1", "not-a-number"])
func watchCommandRejectsInvalidSinceRowID(_ value: String) async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "sinceRowID": [value]],
    flags: []
  )

  await #expect(throws: ParsedValuesError.self) {
    try await WatchCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: { _, _, _, _, _ in
        AsyncThrowingStream { continuation in continuation.finish() }
      }
    )
  }
}

@Test
func watchCommandRunsWithStubStream() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 2
  )
  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
}

@Test(.timeLimit(.minutes(1)))
func watchCommandStopsBridgeStreamWhenDatabaseStreamEnds() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["bbEvents"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  let bridge = WatchBridgeSource()

  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: { _, _, _, _, _ in
        AsyncThrowingStream { continuation in continuation.finish() }
      },
      bridgeStreamProvider: { _ in bridge.makeStream() }
    )
  }
  await bridge.waitForTermination()
}

private final class WatchBridgeSource: @unchecked Sendable {
  private let lock = NSLock()
  private var terminated = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func makeStream() -> AsyncThrowingStream<IMsgEventTailer.Event, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in self?.finish() }
    }
  }

  func waitForTermination() async {
    if lock.withLock({ terminated }) { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if terminated {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func finish() {
    let ready: [CheckedContinuation<Void, Never>]
    lock.lock()
    terminated = true
    ready = waiters
    waiters.removeAll()
    lock.unlock()
    for continuation in ready {
      continuation.resume()
    }
  }
}

@Test
func watchCommandRunsWithJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  let message = Message(
    rowID: 5,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    balloonBundleID: "com.apple.messages.URLBalloonProvider"
  )
  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == true)
  #expect(payload["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(payload["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(payload["chat_name"] as? String == "Group Chat")
  #expect(payload["participants"] as? [String] == ["+123", "me@icloud.com"])
  #expect(payload["balloon_bundle_id"] as? String == "com.apple.messages.URLBalloonProvider")
}

@Test
func watchCommandJsonReportsDirectChatMetadata() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let message = Message(
    rowID: 5,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["is_group"] as? Bool == false)
  #expect(payload["chat_identifier"] as? String == "+123")
  #expect(payload["chat_guid"] as? String == "iMessage;-;+123")
  #expect(payload["chat_name"] as? String == "Direct Chat")
  #expect(payload["participants"] as? [String] == ["+123", "me@icloud.com"])
}

@Test
func watchCommandFlushesPlainOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  #expect(output.contains("hello"))
}

@Test
func watchCommandFlushesJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  let message = Message(
    rowID: 5,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  #expect(output.contains("\"text\":\"hello\""))
}

private final class WatchFreshnessSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let writer: Connection
  private var index = 0

  init(writer: Connection) {
    self.writer = writer
  }

  func next() throws -> Message? {
    try lock.withLock {
      index += 1
      if index == 2 {
        try writer.run(
          "UPDATE chat SET guid = ?, display_name = ? WHERE ROWID = 1",
          "iMessage;+;cli-fresh",
          "CLI Fresh"
        )
        try writer.run("INSERT INTO handle(ROWID, id) VALUES (2, '+999')")
        try writer.run("DELETE FROM chat_handle_join WHERE chat_id = 1")
        try writer.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 2)")
      }
      guard index <= 2 else { return nil }
      return Message(
        rowID: Int64(index),
        chatID: 1,
        sender: index == 1 ? "+123" : "+999",
        text: "message-\(index)",
        date: Date(),
        isFromMe: false,
        service: "iMessage",
        handleID: Int64(index),
        attachmentsCount: 0
      )
    }
  }
}

@Test
func watchCommandReadsFreshMetadataForEveryJSONEmission() async throws {
  let path = try CommandTestDatabase.makePath()
  defer {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
  }
  let writer = try Connection(path)
  _ = try writer.scalar("PRAGMA journal_mode=WAL")
  let reader = try Connection(path)
  let store = try MessageStore(
    connection: reader,
    path: path,
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let sequence = WatchFreshnessSequence(writer: writer)
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      storeFactory: { _ in store },
      contactResolverFactory: { NoOpContactResolver() },
      streamProvider: { _, _, _, _, _ in
        AsyncThrowingStream(unfolding: { try sequence.next() })
      }
    )
  }

  let payloads = try output.split(separator: "\n").map { line in
    try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
  }
  #expect(payloads.count == 2)
  #expect(payloads[0]["chat_name"] as? String == "Test Chat")
  #expect(payloads[0]["participants"] as? [String] == ["+123"])
  #expect(payloads[1]["chat_guid"] as? String == "iMessage;+;cli-fresh")
  #expect(payloads[1]["chat_name"] as? String == "CLI Fresh")
  #expect(payloads[1]["participants"] as? [String] == ["+999"])
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
