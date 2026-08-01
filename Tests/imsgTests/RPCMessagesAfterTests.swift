import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcMessagesAfterPagesMoreThanFiveHundredEqualTimestampRows() async throws {
  let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  let store = try makeMessagesAfterStore(
    rows: (1...502).map { (Int64($0), Int64(1), timestamp) }
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"first","method":"messages.after","params":{"since_rowid":0,"limit":500}}"#
  )

  let first = try #require(output.responses.first?["result"] as? [String: Any])
  let firstMessages = try #require(first["messages"] as? [[String: Any]])
  #expect(firstMessages.compactMap { testInt64($0["id"]) } == (1...500).map(Int64.init))
  #expect(testInt64(first["next_rowid"]) == 500)
  #expect(first["has_more"] as? Bool == true)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"second","method":"messages.after","params":{"since_rowid":500,"limit":500}}"#
  )

  let second = try #require(output.responses.last?["result"] as? [String: Any])
  let secondMessages = try #require(second["messages"] as? [[String: Any]])
  #expect(secondMessages.compactMap { testInt64($0["id"]) } == [501, 502])
  #expect(testInt64(second["next_rowid"]) == 502)
  #expect(second["has_more"] as? Bool == false)
}

@Test
func rpcMessagesAfterFiltersInterleavedChatsWithoutGuessingFromGlobalRowIDs() async throws {
  let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  let store = try makeMessagesAfterStore(
    rows: (1...6).map { rowID in
      (Int64(rowID), rowID.isMultiple(of: 2) ? Int64(2) : Int64(1), timestamp)
    }
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"first","method":"messages.after","params":{"since_rowid":0,"chat_id":2,"limit":2}}"#
  )

  let first = try #require(output.responses.first?["result"] as? [String: Any])
  let firstMessages = try #require(first["messages"] as? [[String: Any]])
  #expect(firstMessages.compactMap { testInt64($0["id"]) } == [2, 4])
  #expect(testInt64(first["next_rowid"]) == 4)
  #expect(first["has_more"] as? Bool == true)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"second","method":"messages.after","params":{"since_rowid":4,"chat_id":2,"limit":2}}"#
  )

  let second = try #require(output.responses.last?["result"] as? [String: Any])
  let secondMessages = try #require(second["messages"] as? [[String: Any]])
  #expect(secondMessages.compactMap { testInt64($0["id"]) } == [6])
  #expect(testInt64(second["next_rowid"]) == 6)
  #expect(second["has_more"] as? Bool == false)
}

@Test
func rpcMessagesAfterIncludesAttachmentMetadataWhenRequested() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithAttachment(
    filename: "/tmp/example.jpg",
    transferName: "example.jpg",
    uti: "public.jpeg",
    mimeType: "image/jpeg"
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"attachments","method":"messages.after","params":{"since_rowid":0,"attachments":true}}"#
  )

  let result = try #require(output.responses.first?["result"] as? [String: Any])
  let messages = try #require(result["messages"] as? [[String: Any]])
  let attachments = try #require(messages.first?["attachments"] as? [[String: Any]])
  #expect(attachments.first?["transfer_name"] as? String == "example.jpg")
}

@Test
func rpcMessagesAfterCanPageReactionEventsWithoutCursorLoss() async throws {
  let store = try makeMessagesAfterReactionStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"reaction","method":"messages.after","params":{"since_rowid":5,"limit":1,"include_reactions":true}}"#
  )

  let first = try #require(output.responses.first?["result"] as? [String: Any])
  let firstMessages = try #require(first["messages"] as? [[String: Any]])
  #expect(firstMessages.compactMap { testInt64($0["id"]) } == [6])
  #expect(firstMessages.first?["is_reaction"] as? Bool == true)
  #expect(testInt64(first["next_rowid"]) == 6)
  #expect(first["has_more"] as? Bool == true)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"message","method":"messages.after","params":{"since_rowid":6,"limit":1,"include_reactions":true}}"#
  )

  let second = try #require(output.responses.last?["result"] as? [String: Any])
  let secondMessages = try #require(second["messages"] as? [[String: Any]])
  #expect(secondMessages.compactMap { testInt64($0["id"]) } == [7])
  #expect(secondMessages.first?["is_reaction"] == nil)
  #expect(testInt64(second["next_rowid"]) == 7)
  #expect(second["has_more"] as? Bool == false)
}

@Test
func rpcMessagesAfterReturnsStableEmptyPageAndAdvertisesCapability() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"empty","method":"messages.after","params":{"since_rowid":999}}"#
  )

  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect((result["messages"] as? [[String: Any]])?.isEmpty == true)
  #expect(testInt64(result["next_rowid"]) == 999)
  #expect(result["has_more"] as? Bool == false)
  #expect(kSupportedRPCMethods.contains("messages.after"))
}

@Test(
  arguments: [
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":-1}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":true}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":1.5}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"chat_id":0}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"limit":0}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"limit":501}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"attachments":"yes"}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"convert_attachments":1}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"include_reactions":"yes"}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":{"since_rowid":0,"extra":true}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"messages.after","params":[]}"#,
  ]
)
func rpcMessagesAfterRejectsInvalidParams(_ request: String) async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(request)

  let error = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(testInt64(error["code"]) == -32602)
}

private func makeMessagesAfterStore(rows: [(Int64, Int64, Date)]) throws -> MessageStore {
  let db = try Connection(.inMemory)
  try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
  try db.run(
    """
    INSERT INTO chat(
      ROWID, chat_identifier, guid, display_name, service_name,
      account_id, account_login, last_addressed_handle
    )
    VALUES
      (1, 'chat-one', 'iMessage;+;chat-one', 'Chat One', 'iMessage', '', '', ''),
      (2, 'chat-two', 'iMessage;+;chat-two', 'Chat Two', 'iMessage', '', '', '')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+15550000001')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (2, 1)")
  for (rowID, chatID, timestamp) in rows {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (?, 1, ?, ?, 0, 'iMessage')
      """,
      rowID,
      "message-\(rowID)",
      CommandTestDatabase.appleEpoch(timestamp)
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)",
      chatID,
      rowID
    )
  }
  return try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
}

private func makeMessagesAfterReactionStore() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try CommandTestDatabase.createSchema(
    db,
    includeChatHandleJoin: true,
    includeReactionColumns: true
  )
  try CommandTestDatabase.seedRPCChat(db)
  try db.run("UPDATE message SET guid = 'parent-guid' WHERE ROWID = 5")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      date, is_from_me, service
    )
    VALUES
      (6, 1, '', 'reaction-guid', 'p:0/parent-guid', 2001, ?, 0, 'iMessage'),
      (7, 1, 'after reaction', 'message-guid', NULL, NULL, ?, 0, 'iMessage')
    """,
    CommandTestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_700_000_001)),
    CommandTestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_700_000_002))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6), (1, 7)")
  return try MessageStore(connection: db, path: ":memory:")
}

private func testInt64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}
