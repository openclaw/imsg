import Foundation
import SQLite
import Testing

@testable import IMsgCore

/// Pins the exact bytes `imsg rpc` writes for a fixed request script against a synthetic
/// database. The RPC layer can move between modules, but a changed byte here is a changed
/// contract for every client that parses this output.
///
/// Requests go in one at a time, each waiting for its response line, because reads run
/// concurrently and would otherwise race each other onto stdout. The child runs with
/// SWIFT_DETERMINISTIC_HASHING so dictionary key order is stable across runs and builds.
/// Set IMSG_RPC_GOLDEN_RECORD to a file path to write the captured bytes there.
enum RPCGoldenFixture {
  static let requests: [String] = [
    #"{"jsonrpc":"2.0","id":1,"method":"chats.list","params":{"limit":10}}"#,
    #"{"jsonrpc":"2.0","id":2,"method":"chats.get","params":{"chat_id":1}}"#,
    #"{"jsonrpc":"2.0","id":3,"method":"messages.history","params":{"chat_id":1,"limit":10}}"#,
    #"{"jsonrpc":"2.0","id":4,"method":"messages.history","params":{"chat_id":2,"limit":10,"attachments":true}}"#,
    #"{"jsonrpc":"2.0","id":5,"method":"messages.after","params":{"since_rowid":2}}"#,
    #"{"jsonrpc":"2.0","id":"str-id","method":"messages.history","params":{"chat_id":1,"limit":1}}"#,
    #"{"jsonrpc":"2.0","id":7,"method":"messages.history","params":{}}"#,
    #"{"jsonrpc":"2.0","id":8,"method":"messages.history","params":{"chat_id":1,"bogus":true}}"#,
    #"{"jsonrpc":"2.0","id":9,"method":"no.such.method"}"#,
    #"{"jsonrpc":"1.0","id":10,"method":"chats.list"}"#,
    #"{"jsonrpc":"2.0","id":11}"#,
    #"[1,2]"#,
  ]

  /// Fixed instants, so no field depends on when the test runs.
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01T00:00:00Z

  static func makeDatabase() throws -> String {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imsg-rpc-golden-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("chat.db").path
    let db = try Connection(path)
    try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES
        (1, 'chat900001', 'iMessage;+;chat900001', 'Golden Group', 'iMessage',
         'iMessage;+;golden@example.com', 'golden@example.com', 'golden@example.com'),
        (2, '+15555550102', 'iMessage;-;+15555550102', '', 'iMessage',
         'iMessage;+;golden@example.com', 'golden@example.com', 'golden@example.com')
      """
    )
    try db.run(
      """
      INSERT INTO handle(ROWID, id)
      VALUES (1, '+15555550101'), (2, '+15555550102'), (3, 'friend@example.com')
      """
    )
    try db.run(
      "INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 3), (2, 2)")
    let rows: [(Int64, Int64, String, TimeInterval, Int64, Int64)] = [
      (1, 1, "hello from the group", 0, 0, 1),
      (2, 0, "a reply from me, with \"quotes\" and a / slash", 60, 1, 1),
      (3, 3, "caf\u{E9} \u{1F600} unicode", 120, 0, 1),
      (4, 2, "direct message", 180, 0, 2),
      (5, 0, "", 240, 1, 2),
    ]
    for (rowID, handleID, text, offset, fromMe, chatID) in rows {
      try db.run(
        """
        INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
        VALUES (?, ?, ?, ?, ?, 'iMessage')
        """,
        rowID, handleID, text,
        CommandTestDatabase.appleEpoch(base.addingTimeInterval(offset)), fromMe
      )
      try db.run(
        "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
    }
    try db.run(
      """
      INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
      VALUES (1, '/nonexistent/golden/photo.jpg', 'photo.jpg', 'public.jpeg', 'image/jpeg', 2048, 0)
      """
    )
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (5, 1)")
    return path
  }

  /// Runs the built `imsg rpc` and returns everything it wrote to stdout.
  static func transcript(databasePath: String) throws -> Data {
    let process = Process()
    process.executableURL = try goldenIMsgExecutableURL()
    process.arguments = ["rpc", "--db", databasePath]
    var environment = ProcessInfo.processInfo.environment
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let collector = GoldenLineCollector(handle: output.fileHandleForReading)
    try process.run()
    collector.start()
    for (index, request) in requests.enumerated() {
      try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
      guard collector.waitForLines(index + 1, timeout: 10) else {
        process.terminate()
        throw GoldenTimeout(request: request)
      }
    }
    try input.fileHandleForWriting.close()
    #expect(!ProcessTimeout.waitUntilExit(process, timeout: 10))
    return collector.finish()
  }

  struct GoldenTimeout: Error, CustomStringConvertible {
    let request: String
    var description: String { "no response within 10s to \(request)" }
  }

  private static func goldenIMsgExecutableURL() throws -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
      cwd.appendingPathComponent(".build/debug/imsg"),
      cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/imsg"),
      cwd.appendingPathComponent(".build/x86_64-apple-macosx/debug/imsg"),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    throw CocoaError(.fileNoSuchFile)
  }
}

/// Reads a pipe on its own thread and lets the caller wait for a number of complete lines.
final class GoldenLineCollector: @unchecked Sendable {
  private let condition = NSCondition()
  private let handle: FileHandle
  private var data = Data()
  private var finished = false

  init(handle: FileHandle) {
    self.handle = handle
  }

  func start() {
    Thread { [self] in
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        condition.lock()
        if count > 0 {
          data.append(contentsOf: buffer.prefix(count))
        } else {
          finished = true
        }
        condition.broadcast()
        condition.unlock()
        if count <= 0 { break }
      }
    }.start()
  }

  func waitForLines(_ count: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }
    while data.reduce(0, { $0 + ($1 == 0x0A ? 1 : 0) }) < count {
      if finished || !condition.wait(until: deadline) { return false }
    }
    return true
  }

  func finish() -> Data {
    let deadline = Date().addingTimeInterval(10)
    condition.lock()
    defer { condition.unlock() }
    while !finished, condition.wait(until: deadline) {}
    return data
  }
}

@Test
func rpcOutputMatchesGoldenTranscript() throws {
  let path = try RPCGoldenFixture.makeDatabase()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let actual = try RPCGoldenFixture.transcript(databasePath: path)
  if let record = ProcessInfo.processInfo.environment["IMSG_RPC_GOLDEN_RECORD"] {
    try actual.write(to: URL(fileURLWithPath: record))
  }
  let expected = Data((RPCGoldenTranscript.lines.joined(separator: "\n") + "\n").utf8)
  #expect(
    actual == expected,
    "rpc output changed:\n\(String(decoding: actual, as: UTF8.self))")
}
