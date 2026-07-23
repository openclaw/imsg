import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

/// Builds a minimal chat.db (one chat, one message with the given text) at a
/// fresh temp path, for exercising `--redact-codes` through `HistoryCommand`,
/// which opens its store from a `--db` path rather than accepting an
/// injected store. Mirrors `CommandTestDatabase.seedRPCChat`'s shape.
private func makeDBFileWithMessageText(_ text: String) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let path = dir.appendingPathComponent("chat.db").path
  let db = try Connection(path)
  try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
  try seedOneMessageChat(db, text: text)
  return path
}

/// Builds a minimal in-memory store (one chat, one message with the given
/// text), for exercising `--redact-codes` through `RPCServer`, which accepts
/// an injected `MessageStore`.
private func makeStoreWithMessageText(_ text: String) throws -> MessageStore {
  let db = try Connection(.inMemory)
  try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
  try seedOneMessageChat(db, text: text)
  return try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
}

private func seedOneMessageChat(_ db: Connection, text: String) throws {
  try db.run(
    """
    INSERT INTO chat(
      ROWID, chat_identifier, guid, display_name, service_name,
      account_id, account_login, last_addressed_handle
    )
    VALUES (
      1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group Chat', 'iMessage',
      'iMessage;+;me@icloud.com', 'me@icloud.com', 'me@icloud.com'
    )
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1)")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (1, 1, ?, ?, 0, 'iMessage')
    """,
    text,
    CommandTestDatabase.appleEpoch(Date())
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - CLI: history

@Test
func historyCommandRedactsCodesWhenFlagSet() async throws {
  let path = try makeDBFileWithMessageText("Your Ticketmaster code: 483920")
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["jsonOutput", CommandSignatures.redactCodesFlagLabel]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["text"] as? String == "Your Ticketmaster code: [redacted]")
}

@Test
func historyCommandLeavesTextAloneWithoutFlag() async throws {
  let path = try makeDBFileWithMessageText("Your Ticketmaster code: 483920")
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { NoOpContactResolver() }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["text"] as? String == "Your Ticketmaster code: 483920")
}

// MARK: - RPC: messages.history

@Test
func rpcMessagesHistoryRedactsCodesWhenServerConfigured() async throws {
  let store = try makeStoreWithMessageText("483920 is your verification code.")
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, redactCodes: true, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.count == 1)
  #expect(messages.first?["text"] as? String == "[redacted] is your verification code.")
}

@Test
func rpcMessagesHistoryLeavesTextAloneWithoutRedactCodes() async throws {
  let store = try makeStoreWithMessageText("483920 is your verification code.")
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, redactCodes: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.first?["text"] as? String == "483920 is your verification code.")
}

// MARK: - RuntimeOptions

@Test
func runtimeOptionsRedactCodesDefaultsFalse() {
  let values = ParsedValues(positional: [], options: [:], flags: [])
  #expect(RuntimeOptions(parsedValues: values).redactCodes == false)
}

@Test
func runtimeOptionsRedactCodesFromFlag() {
  let values = ParsedValues(
    positional: [], options: [:], flags: [CommandSignatures.redactCodesFlagLabel])
  #expect(RuntimeOptions(parsedValues: values).redactCodes == true)
}

// MARK: - argv extraction (regression: --redact-codes before the subcommand
// used to break parsing entirely, since only --read-only was pre-scanned)

@Test
func extractLeadingGlobalFlagsDropsRedactCodesBeforeSubcommand() {
  let (readOnly, redactCodes, argv) = CommandRouter.extractLeadingGlobalFlags(
    ["imsg", "--redact-codes", "history", "--chat-id", "1"])
  #expect(readOnly == false)
  #expect(redactCodes == true)
  #expect(argv == ["imsg", "history", "--chat-id", "1"])
}

@Test
func extractLeadingGlobalFlagsDropsBothFlagsBeforeSubcommand() {
  let (readOnly, redactCodes, argv) = CommandRouter.extractLeadingGlobalFlags(
    ["imsg", "--read-only", "--redact-codes", "history", "--chat-id", "1"])
  #expect(readOnly == true)
  #expect(redactCodes == true)
  #expect(argv == ["imsg", "history", "--chat-id", "1"])
}

@Test
func extractLeadingGlobalFlagsKeepsRedactCodesAfterSubcommand() {
  let (_, redactCodes, argv) = CommandRouter.extractLeadingGlobalFlags(
    ["imsg", "history", "--redact-codes"])
  #expect(argv == ["imsg", "history", "--redact-codes"])
  #expect(redactCodes == false)
}

@Test
func routerParsesRedactCodesBeforeSubcommand() async throws {
  // Regression test for the real bug: Commander's root program expects the
  // subcommand name as argv[1]; --redact-codes previously wasn't stripped
  // from that position, so the whole invocation failed with "requires a
  // subcommand" instead of running history with redaction enabled.
  let path = try makeDBFileWithMessageText("Your Ticketmaster code: 483920")
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(
      argv: ["imsg", "--redact-codes", "history", "--db", path, "--chat-id", "1", "--json"])
  }
  #expect(status == 0)
  #expect(!output.contains("requires a subcommand"))
  let payload = try jsonObject(from: output)
  #expect(payload["text"] as? String == "Your Ticketmaster code: [redacted]")
}

@Test
func routerParsesBothGlobalFlagsBeforeSubcommand() async throws {
  let path = try makeDBFileWithMessageText("Your Ticketmaster code: 483920")
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(
      argv: [
        "imsg", "--read-only", "--redact-codes", "history", "--db", path, "--chat-id", "1",
        "--json",
      ])
  }
  #expect(status == 0)
  #expect(!output.contains("requires a subcommand"))
  let payload = try jsonObject(from: output)
  #expect(payload["text"] as? String == "Your Ticketmaster code: [redacted]")
}
