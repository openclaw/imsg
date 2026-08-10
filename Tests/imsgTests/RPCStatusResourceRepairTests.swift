import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func repairResult(_ output: TestRPCOutput, at index: Int = 0) throws -> [String: Any] {
  try #require(output.responses[index]["result"] as? [String: Any])
}

private func makeDatabaseGeneration(
  path: String,
  name: String,
  text: String,
  usesWAL: Bool = false
) throws {
  let db = try Connection(path)
  if usesWAL {
    let journalMode = try #require(try db.scalar("PRAGMA journal_mode=WAL") as? String)
    #expect(journalMode.lowercased() == "wal")
  }
  try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
  try CommandTestDatabase.seedRPCChat(db)
  try db.run(
    "UPDATE chat SET display_name = ?, guid = ? WHERE ROWID = 1",
    name,
    "iMessage;+;\(name)"
  )
  try db.run("UPDATE message SET text = ? WHERE ROWID = 5", text)
  if usesWAL {
    _ = try db.scalar("PRAGMA wal_checkpoint(TRUNCATE)")
  }
}

private func atomicallyReplaceDatabase(at path: String, with replacementPath: String) throws {
  _ = try FileManager.default.replaceItemAt(
    URL(fileURLWithPath: path),
    withItemAt: URL(fileURLWithPath: replacementPath)
  )
}

private final class RPCGenerationWatchHarness: @unchecked Sendable {
  let source = ControlledWatchSource()
  private let lock = NSLock()
  private var watchers: [MessageWatcher] = []

  func stream(watcher: MessageWatcher) -> AsyncThrowingStream<Message, Error> {
    lock.withLock { watchers.append(watcher) }
    return source.makeStream()
  }

  func capturedWatchers() -> [MessageWatcher] {
    lock.withLock { watchers }
  }
}

@Test(.timeLimit(.minutes(1)))
func rpcWALSnapshotFailsClosedThenRecoversAfterReadableReplacement() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let sourcePath = root.appendingPathComponent("source.db").path
  let snapshotPath = root.appendingPathComponent("snapshot.db").path

  do {
    let source = try Connection(sourcePath)
    _ = try source.scalar("PRAGMA journal_mode=WAL")
    try CommandTestDatabase.createSchema(source, includeChatHandleJoin: true)
    try CommandTestDatabase.seedRPCChat(source)
    let destination = try Connection(snapshotPath)
    try source.backup(usingConnection: destination).step()
  }

  #expect(!FileManager.default.fileExists(atPath: snapshotPath + "-wal"))
  #expect(!FileManager.default.fileExists(atPath: snapshotPath + "-shm"))
  do {
    _ = try MessageStore(path: snapshotPath)
    Issue.record("expected a sidecar-less WAL snapshot to fail schema readiness")
  } catch {}

  let output = TestRPCOutput()
  let server = RPCServer(
    databasePath: snapshotPath,
    verbose: false,
    output: output,
    isBridgeReady: { false }
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"down","method":"status"}"#)
  let down = try repairResult(output)
  #expect((down["database"] as? [String: Any])?["ready"] as? Bool == false)
  #expect(!(down["methods"] as? [String] ?? []).contains("messages.stats"))

  let replacementPath = try CommandTestDatabase.makePath()
  try FileManager.default.removeItem(atPath: snapshotPath)
  try FileManager.default.copyItem(atPath: replacementPath, toPath: snapshotPath)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"up","method":"status"}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"stats","method":"messages.stats"}"#)
  let up = try repairResult(output, at: 1)
  #expect((up["database"] as? [String: Any])?["ready"] as? Bool == true)
  #expect((up["methods"] as? [String] ?? []).contains("messages.stats"))
  #expect(try !repairResult(output, at: 2).isEmpty)
  #expect(output.errors.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func rpcRotatesNewRequestsAcrossDatabaseGenerationsAndRetainsActiveWatch() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let configuredPath = root.appendingPathComponent("chat.db").path
  let generationBPath = root.appendingPathComponent("generation-b.db").path
  let generationCPath = root.appendingPathComponent("generation-c.db").path
  try makeDatabaseGeneration(
    path: configuredPath,
    name: "Generation A",
    text: "message-a",
    usesWAL: true
  )
  try makeDatabaseGeneration(path: generationBPath, name: "Generation B", text: "message-b")
  try makeDatabaseGeneration(path: generationCPath, name: "Generation C", text: "message-c")

  let output = TestRPCOutput()
  let watchHarness = RPCGenerationWatchHarness()
  let server = RPCServer(
    databasePath: configuredPath,
    verbose: false,
    output: output,
    isBridgeReady: { false },
    watchStreamProvider: { watcher, _, _, _, _ in watchHarness.stream(watcher: watcher) }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"warm-a","method":"status"}"#)
  let warm = try repairResult(output)
  #expect((warm["database"] as? [String: Any])?["ready"] as? Bool == true)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"watch-a","method":"watch.subscribe","params":{"since_rowid":0}}"#)
  await watchHarness.source.waitForStreams(1)
  let generationAMessage = Message(
    rowID: 5,
    chatID: 1,
    sender: "+123",
    text: "message-a",
    date: Date(timeIntervalSince1970: 1_700_000_000),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0
  )
  watchHarness.source.yield(generationAMessage)
  await output.waitForOutputCount(3)

  try atomicallyReplaceDatabase(at: configuredPath, with: generationBPath)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status-b","method":"status"}"#)
  let statusB = try repairResult(output, at: 2)
  let databaseB = try #require(statusB["database"] as? [String: Any])
  try #require(databaseB["ready"] as? Bool == true, "snapshot: \(databaseB)")
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"chats-b","method":"chats.list","params":{"limit":1}}"#)
  let chatsB = try #require(try repairResult(output, at: 3)["chats"] as? [[String: Any]])
  #expect(chatsB.first?["display_name"] as? String == "Generation B")

  let firstNotification = try #require(output.notifications.first)
  let watchParams = try #require(firstNotification["params"] as? [String: Any])
  let watchedMessage = try #require(watchParams["message"] as? [String: Any])
  #expect(watchedMessage["chat_name"] as? String == "Generation A")
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"watch-b","method":"watch.subscribe","params":{"since_rowid":0}}"#)
  await watchHarness.source.waitForStreams(2)
  let generationWatchers = watchHarness.capturedWatchers()
  #expect(generationWatchers.count == 2)
  let generationAWatcher = try #require(generationWatchers.first)
  let generationBWatcher = try #require(generationWatchers.last)
  #expect(generationAWatcher !== generationBWatcher)
  #expect(await server.subscriptions.count == 2)

  try FileManager.default.removeItem(atPath: configuredPath)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status-missing","method":"status"}"#)
  let missing = try repairResult(output, at: 5)
  #expect((missing["database"] as? [String: Any])?["ready"] as? Bool == false)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"request-missing","method":"chats.list"}"#)
  let unavailable = try #require(output.errors.last?["error"] as? [String: Any])
  #expect(unavailable["code"] as? Int == -32002)

  try FileManager.default.moveItem(
    at: URL(fileURLWithPath: generationCPath),
    to: URL(fileURLWithPath: configuredPath)
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status-c","method":"status"}"#)
  let statusC = try repairResult(output, at: 6)
  #expect((statusC["database"] as? [String: Any])?["ready"] as? Bool == true)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"history-c","method":"messages.history","params":{"chat_id":1}}"#)
  let historyC = try #require(try repairResult(output, at: 7)["messages"] as? [[String: Any]])
  #expect(historyC.first?["text"] as? String == "message-c")

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"stop-a","method":"watch.unsubscribe","params":{"subscription":1}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"stop-b","method":"watch.unsubscribe","params":{"subscription":2}}"#)
  await watchHarness.source.waitForTerminations(2)
}
