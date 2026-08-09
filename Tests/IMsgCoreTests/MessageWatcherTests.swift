import Foundation
import SQLite
import Testing

@testable import IMsgCore

private struct WatcherTestStore {
  let store: MessageStore
  let insertMessage: (Int64, String) throws -> Void
  let insertUnjoinedMessage: (Int64, String) throws -> Void
  let joinMessage: (Int64, Int64) throws -> Void
}

private enum WatcherTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (1, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    return try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false)
  }

  static func makeMutableStore(path: String = ":memory:") throws -> WatcherTestStore {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

    let store = try MessageStore(
      connection: db, path: path, hasAttributedBody: false, hasReactionColumns: false)
    return WatcherTestStore(
      store: store,
      insertMessage: { rowID, text in
        try insertMutableMessage(store: store, rowID: rowID, text: text)
        try joinMutableMessage(store: store, rowID: rowID, chatID: 1)
      },
      insertUnjoinedMessage: { rowID, text in
        try insertMutableMessage(store: store, rowID: rowID, text: text)
      },
      joinMessage: { rowID, chatID in
        try joinMutableMessage(store: store, rowID: rowID, chatID: chatID)
      }
    )
  }

  private static func insertMutableMessage(store: MessageStore, rowID: Int64, text: String)
    throws
  {
    _ = try store.withConnection { db in
      try db.run(
        """
        INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
        VALUES (?, 1, ?, ?, 0, 'iMessage')
        """,
        rowID,
        text,
        appleEpoch(Date())
      )
    }
  }

  private static func joinMutableMessage(store: MessageStore, rowID: Int64, chatID: Int64)
    throws
  {
    _ = try store.withConnection { db in
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
    }
  }
}

private actor WatcherPollSignal {
  private var didPoll = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    guard !didPoll else { return }
    didPoll = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }

  func wait() async {
    if didPoll { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private func nextMessage(
  from stream: AsyncThrowingStream<Message, Error>,
  timeoutNanoseconds: UInt64 = 2_000_000_000
) async throws -> Message? {
  try await withThrowingTaskGroup(of: Message?.self) { group in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: timeoutNanoseconds)
      return nil
    }

    let message = try await group.next() ?? nil
    group.cancelAll()
    return message
  }
}

private func drainWatcher(
  _ stream: AsyncThrowingStream<Message, Error>
) async -> (messages: [Message], error: Error?) {
  var messages: [Message] = []
  do {
    for try await message in stream {
      messages.append(message)
    }
    return (messages, nil)
  } catch {
    return (messages, error)
  }
}

@Test
func messageWatcherConfigurationDefaultsToBoundedBuffer() {
  #expect(MessageWatcherConfiguration().bufferLimit == 256)
}

@Test
func messageWatcherConfigurationClampsInvalidDirectBufferLimits() {
  var configuration = MessageWatcherConfiguration(bufferLimit: 0)
  #expect(configuration.bufferLimit == 1)

  configuration.bufferLimit = -10
  #expect(configuration.bufferLimit == 1)

  configuration.bufferLimit = 4097
  #expect(configuration.bufferLimit == 4096)
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherDrainsBufferedMessagesBeforeOverflow() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  try fixture.insertMessage(1, "one")
  try fixture.insertMessage(2, "two")
  try fixture.insertMessage(3, "three")
  let pollSignal = WatcherPollSignal()
  let watcher = MessageWatcher(store: fixture.store) {
    Task { await pollSignal.signal() }
  }
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10,
      bufferLimit: 2
    )
  )

  await pollSignal.wait()
  let result = await drainWatcher(stream)
  #expect(result.messages.map(\.rowID) == [1, 2])
  let overflow = try #require(result.error as? MessageWatcherOverflowError)
  #expect(overflow.resumeAfterRowID == 2)
  #expect(overflow.resumeAfterRowID < 3)
}

@Test(.timeLimit(.minutes(1)))
func messageWatcherFiltersBeforeBufferAdmission() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  try fixture.insertMessage(1, "filtered")
  try fixture.insertMessage(2, "two")
  try fixture.insertMessage(3, "three")
  try fixture.insertMessage(4, "four")
  try fixture.store.withConnection { db in
    try db.run("INSERT INTO handle(ROWID, id) VALUES (2, '+999')")
    try db.run("UPDATE message SET handle_id = 2 WHERE ROWID = 1")
  }
  let pollSignal = WatcherPollSignal()
  let watcher = MessageWatcher(store: fixture.store) {
    Task { await pollSignal.signal() }
  }
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0,
      fallbackPollInterval: nil,
      batchLimit: 10,
      bufferLimit: 2
    ),
    filter: MessageFilter(participants: ["+123"])
  )

  await pollSignal.wait()
  let result = await drainWatcher(stream)
  #expect(result.messages.map(\.rowID) == [2, 3])
  let overflow = try #require(result.error as? MessageWatcherOverflowError)
  #expect(overflow.resumeAfterRowID == 3)
  #expect(overflow.resumeAfterRowID < 4)
}

@Test
func messageWatcherYieldsExistingMessages() async throws {
  let store = try WatcherTestDatabase.makeStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(debounceInterval: 0.01, batchLimit: 10)
  )

  let task = Task { () throws -> Message? in
    var iterator = stream.makeAsyncIterator()
    return try await iterator.next()
  }

  let message = try await task.value
  #expect(message?.text == "hello")
}

@Test
func messageWatcherFallbackPollYieldsMessagesWithoutFileEvents() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  let watcher = MessageWatcher(store: fixture.store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 60,
      fallbackPollInterval: 0.01,
      batchLimit: 10
    )
  )

  let task = Task { () throws -> Message? in
    var iterator = stream.makeAsyncIterator()
    return try await iterator.next()
  }

  try await Task.sleep(nanoseconds: 20_000_000)
  try fixture.insertMessage(2, "fallback")

  let message = try await task.value
  #expect(message?.rowID == 2)
  #expect(message?.text == "fallback")
}

@Test
func messageWatcherRetriesUnresolvedChatMetadata() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  let watcher = MessageWatcher(store: fixture.store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      fallbackPollInterval: 0.01,
      batchLimit: 10
    )
  )

  let task = Task { try await nextMessage(from: stream) }

  try await Task.sleep(nanoseconds: 20_000_000)
  try fixture.insertUnjoinedMessage(2, "unresolved")
  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.joinMessage(2, 1)

  let message = try await task.value
  #expect(message?.rowID == 2)
  #expect(message?.chatID == 1)
  #expect(message?.text == "unresolved")
}

@Test
func messageWatcherSkipsPersistentlyUnresolvedChatMetadata() async throws {
  let fixture = try WatcherTestDatabase.makeMutableStore()
  let watcher = MessageWatcher(store: fixture.store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: 0,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.001,
      fallbackPollInterval: 0.01,
      batchLimit: 10
    )
  )

  let task = Task { try await nextMessage(from: stream) }

  try await Task.sleep(nanoseconds: 20_000_000)
  try fixture.insertUnjoinedMessage(2, "orphan")
  try fixture.insertMessage(3, "after orphan")

  let message = try await task.value
  #expect(message?.rowID == 3)
  #expect(message?.chatID == 1)
  #expect(message?.text == "after orphan")
}

#if os(macOS)
  @Test
  func messageWatcherRearmsSidecarAfterRotation() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "imsg-watch-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: tempDirectory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: tempDirectory)
    }

    let dbURL = tempDirectory.appendingPathComponent("chat.db")
    let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
    FileManager.default.createFile(atPath: dbURL.path, contents: Data())
    FileManager.default.createFile(atPath: walURL.path, contents: Data())
    FileManager.default.createFile(atPath: shmURL.path, contents: Data())

    let fixture = try WatcherTestDatabase.makeMutableStore(path: dbURL.path)
    let watcher = MessageWatcher(store: fixture.store)
    let stream = watcher.stream(
      chatID: nil,
      sinceRowID: 0,
      configuration: MessageWatcherConfiguration(
        debounceInterval: 0.01,
        fallbackPollInterval: nil,
        batchLimit: 10
      )
    )

    try await Task.sleep(nanoseconds: 100_000_000)
    try FileManager.default.moveItem(
      at: walURL,
      to: tempDirectory.appendingPathComponent("chat.db-wal.old")
    )
    FileManager.default.createFile(atPath: walURL.path, contents: Data())
    try await Task.sleep(nanoseconds: 100_000_000)

    try fixture.insertMessage(2, "rotated")
    let walHandle = try FileHandle(forWritingTo: walURL)
    try walHandle.seekToEnd()
    try walHandle.write(contentsOf: Data("x".utf8))
    try walHandle.close()

    let message = try await nextMessage(from: stream, timeoutNanoseconds: 3_000_000_000)
    #expect(message?.rowID == 2)
    #expect(message?.text == "rotated")
  }
#endif
