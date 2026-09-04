import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func makeWALFixture() throws -> (path: String, writer: Connection, store: MessageStore) {
  let path = try CommandTestDatabase.makePath()
  let writer = try Connection(path)
  _ = try writer.scalar("PRAGMA journal_mode=WAL")
  let reader = try Connection(path)
  let store = try MessageStore(
    connection: reader,
    path: path,
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  return (path, writer, store)
}

private func rpcResult(_ output: TestRPCOutput, id: String) -> [String: Any]? {
  output.responses.first { $0["id"] as? String == id }?["result"] as? [String: Any]
}

private func rpcMessages(_ output: TestRPCOutput, id: String) -> [[String: Any]] {
  rpcResult(output, id: id)?["messages"] as? [[String: Any]] ?? []
}

@Test
func rpcFiniteRequestsAndRoutingReadFreshWALMetadata() async throws {
  let fixture = try makeWALFixture()
  defer {
    try? FileManager.default.removeItem(
      at: URL(fileURLWithPath: fixture.path).deletingLastPathComponent())
  }
  let output = TestRPCOutput()
  var routedGUID: String?
  let server = RPCServer(
    store: fixture.store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      if action == .sendMessage {
        routedGUID = params["chatGuid"] as? String
      }
      return [:]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"warm-list","method":"chats.list","params":{"limit":10}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"warm-history","method":"messages.history","params":{"chat_id":1}}"#)

  try fixture.writer.run(
    "UPDATE chat SET chat_identifier = ?, guid = ?, display_name = ? WHERE ROWID = 1",
    "fresh-chat",
    "iMessage;+;fresh-chat",
    "Fresh Name"
  )
  try fixture.writer.run("INSERT INTO handle(ROWID, id) VALUES (2, '+999')")
  try fixture.writer.run("DELETE FROM chat_handle_join WHERE chat_id = 1")
  try fixture.writer.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 2)")

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"fresh-list","method":"chats.list","params":{"limit":10}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"fresh-history","method":"messages.history","params":{"chat_id":1}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"fresh-after","method":"messages.after","params":{"since_rowid":0,"chat_id":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"fresh-route","method":"send","params":{"chat_id":1,"text":"hello","transport":"bridge"}}"#
  )

  let chats = rpcResult(output, id: "fresh-list")?["chats"] as? [[String: Any]] ?? []
  #expect(chats.first?["guid"] as? String == "iMessage;+;fresh-chat")
  #expect(chats.first?["name"] as? String == "Fresh Name")
  #expect(chats.first?["participants"] as? [String] == ["+999"])
  for id in ["fresh-history", "fresh-after"] {
    let message = rpcMessages(output, id: id).first
    #expect(message?["chat_guid"] as? String == "iMessage;+;fresh-chat")
    #expect(message?["chat_name"] as? String == "Fresh Name")
    #expect(message?["participants"] as? [String] == ["+999"])
  }
  #expect(routedGUID == "iMessage;+;fresh-chat")
}

@Test
func deletedWarmChatIDRejectsBeforeSendOrBridgeDispatch() async throws {
  let fixture = try makeWALFixture()
  defer {
    try? FileManager.default.removeItem(
      at: URL(fileURLWithPath: fixture.path).deletingLastPathComponent())
  }
  let output = TestRPCOutput()
  var sendCount = 0
  var bridgeCount = 0
  let server = RPCServer(
    store: fixture.store,
    verbose: false,
    output: output,
    sendMessage: { _ in sendCount += 1 },
    invokeBridge: { _, _ in
      bridgeCount += 1
      return [:]
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"warm","method":"messages.history","params":{"chat_id":1}}"#)
  try fixture.writer.run("DELETE FROM chat WHERE ROWID = 1")

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"send-deleted","method":"send","params":{"chat_id":1,"text":"no"}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rename-deleted","method":"group.rename","params":{"chat_id":1,"name":"No"}}"#
  )

  #expect(output.errors.count == 2)
  #expect(sendCount == 0)
  #expect(bridgeCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func rpcWatchReadsMetadataAndParticipantsForEveryEmission() async throws {
  let fixture = try makeWALFixture()
  defer {
    try? FileManager.default.removeItem(
      at: URL(fileURLWithPath: fixture.path).deletingLastPathComponent())
  }
  let output = TestRPCOutput()
  let (stream, continuation) = AsyncThrowingStream<Message, Error>.makeStream()
  let server = RPCServer(
    store: fixture.store,
    verbose: false,
    output: output,
    watchStreamProvider: { _, _, _, _, _ in stream }
  )
  let first = Message(
    rowID: 10,
    chatID: 1,
    sender: "+123",
    text: "first",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0
  )
  let second = Message(
    rowID: 11,
    chatID: 1,
    sender: "+999",
    text: "second",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: 2,
    attachmentsCount: 0
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"watch","method":"watch.subscribe","params":{}}"#)
  continuation.yield(first)
  await output.waitForOutputCount(2)

  try fixture.writer.run(
    "UPDATE chat SET guid = ?, display_name = ? WHERE ROWID = 1",
    "iMessage;+;fresh-watch",
    "Fresh Watch"
  )
  try fixture.writer.run("INSERT INTO handle(ROWID, id) VALUES (2, '+999')")
  try fixture.writer.run("DELETE FROM chat_handle_join WHERE chat_id = 1")
  try fixture.writer.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 2)")
  continuation.yield(second)
  continuation.finish()
  await output.waitForOutputCount(3)
  await server.subscriptions.waitUntilEmpty()

  let messages = output.notifications.compactMap { notification -> [String: Any]? in
    let params = notification["params"] as? [String: Any]
    return params?["message"] as? [String: Any]
  }
  #expect(messages.count == 2)
  #expect(messages[0]["chat_name"] as? String == "Test Chat")
  #expect(messages[0]["participants"] as? [String] == ["+123"])
  #expect(messages[1]["chat_guid"] as? String == "iMessage;+;fresh-watch")
  #expect(messages[1]["chat_name"] as? String == "Fresh Watch")
  #expect(messages[1]["participants"] as? [String] == ["+999"])
}
