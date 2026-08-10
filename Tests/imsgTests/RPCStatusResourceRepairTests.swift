import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func repairResult(_ output: TestRPCOutput, at index: Int = 0) throws -> [String: Any] {
  try #require(output.responses[index]["result"] as? [String: Any])
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
