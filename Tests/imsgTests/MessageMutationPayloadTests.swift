import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func mutationPayloadAddsOptionalFieldsWithoutChangingNormalMessages() throws {
  let original = Message(
    rowID: 7, chatID: 1, sender: "sender", text: "body",
    date: Date(timeIntervalSince1970: 100), isFromMe: false,
    service: "iMessage", handleID: 1, attachmentsCount: 0, guid: "guid")
  let normal = try MessagePayload(message: original, attachments: []).asDictionary()
  #expect(normal["type"] == nil)
  #expect(normal["edited_at"] == nil)
  #expect(normal["unsent_at"] == nil)
  let edited = Message(
    rowID: 7, chatID: 1, sender: "sender", text: "changed",
    date: original.date, isFromMe: false, service: "iMessage", handleID: 1,
    attachmentsCount: 0, guid: "guid", editedAt: original.date,
    mutationEvent: .edited)
  let payload = try MessagePayload(message: edited, attachments: []).asDictionary()
  #expect(payload["id"] as? Int64 == 7)
  #expect(payload["guid"] as? String == "guid")
  #expect(payload["type"] as? String == "edited")
  #expect(payload["text"] as? String == "changed")
  #expect(payload["edited_at"] as? String == "1970-01-01T00:01:40.000Z")
  #expect(payload["created_at"] as? String == normal["created_at"] as? String)
}

@Test
func historyAndRPCReturnMutationTimestampsFromDatabase() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let db = try Connection(path)
  try db.execute("ALTER TABLE message ADD COLUMN date_edited INTEGER")
  try db.execute("ALTER TABLE message ADD COLUMN date_retracted INTEGER")
  try db.run("UPDATE message SET date_edited = 2000000000, date_retracted = 3000000000")
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"]],
    flags: ["jsonOutput", "noContacts"])
  let (text, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(values: values, runtime: RuntimeOptions(parsedValues: values))
  }
  let payload = try commandTestJSONObject(from: text)
  #expect(payload["text"] as? String == "")
  #expect((payload["attachments"] as? [Any])?.isEmpty == true)
  #expect(payload["edited_at"] as? String == "2001-01-01T00:00:02.000Z")
  #expect(payload["unsent_at"] as? String == "2001-01-01T00:00:03.000Z")
  #expect(payload["type"] == nil)
  let output = TestRPCOutput()
  let server = RPCServer(store: try MessageStore(path: path), verbose: false, output: output)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1}}"#)
  let response = try #require(output.responses.first?["result"] as? [String: Any])
  let messages = try #require(response["messages"] as? [[String: Any]])
  #expect(messages.first?["unsent_at"] as? String == payload["unsent_at"] as? String)
  #expect(messages.first?["text"] as? String == "")
}

@Test
func historyAndRPCClearAnUnsendRecordedOnlyAsRetractedParts() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let db = try Connection(path)
  try db.execute("ALTER TABLE message ADD COLUMN date_edited INTEGER")
  try db.execute("ALTER TABLE message ADD COLUMN date_retracted INTEGER")
  try db.execute("ALTER TABLE message ADD COLUMN message_summary_info BLOB")
  try db.run(
    """
    UPDATE message SET text = NULL, date_edited = 2000000000, date_retracted = 0,
      message_summary_info = ?
    """, try fullyRetractedSummaryInfo())
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"]],
    flags: ["jsonOutput", "noContacts"])
  let (text, _) = try await StdoutCapture.capture {
    try await HistoryCommand.run(values: values, runtime: RuntimeOptions(parsedValues: values))
  }
  let payload = try commandTestJSONObject(from: text)
  #expect(payload["text"] as? String == "")
  #expect((payload["attachments"] as? [Any])?.isEmpty == true)
  #expect(payload["unsent_at"] as? String == "2001-01-01T00:00:02.000Z")
  let output = TestRPCOutput()
  let server = RPCServer(store: try MessageStore(path: path), verbose: false, output: output)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1,"attachments":true}}"#
  )
  let response = try #require(output.responses.first?["result"] as? [String: Any])
  let message = try #require((response["messages"] as? [[String: Any]])?.first)
  #expect(message["unsent_at"] as? String == payload["unsent_at"] as? String)
  #expect(message["text"] as? String == "")
  #expect((message["attachments"] as? [Any])?.isEmpty == true)
}

@Test
func rpcDropsReactionsOnAnUnsendRecordedOnlyAsRetractedParts() async throws {
  let db = try CommandTestDatabase.makeStoreForRPCWithReaction().withConnection { $0 }
  try db.execute("ALTER TABLE message ADD COLUMN date_edited INTEGER")
  try db.execute("ALTER TABLE message ADD COLUMN date_retracted INTEGER")
  try db.execute("ALTER TABLE message ADD COLUMN message_summary_info BLOB")
  func reactions() async throws -> [Any]? {
    let output = TestRPCOutput()
    let server = RPCServer(
      store: try MessageStore(connection: db, path: ":memory:"), verbose: false, output: output)
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1}}"#)
    let response = try #require(output.responses.first?["result"] as? [String: Any])
    let messages = try #require(response["messages"] as? [[String: Any]])
    return messages.first { $0["id"] as? Int64 == 5 }?["reactions"] as? [Any]
  }
  #expect(try await reactions()?.count == 1)
  try db.run(
    """
    UPDATE message SET text = NULL, date_edited = 2000000000, message_summary_info = ?
    WHERE ROWID = 5
    """, try fullyRetractedSummaryInfo())
  #expect(try await reactions()?.isEmpty == true)
}

private func fullyRetractedSummaryInfo() throws -> Blob {
  let data = try PropertyListSerialization.data(
    fromPropertyList: ["otr": ["0": ["lo": 0, "le": 1]], "rp": [0]], format: .binary, options: 0)
  return Blob(bytes: Array(data))
}
