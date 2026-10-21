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
