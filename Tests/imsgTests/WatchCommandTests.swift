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
  MessageWatcherConfiguration
) -> AsyncThrowingStream<Message, Error> {
  return { _, _, _, _ in
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

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
