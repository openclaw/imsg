import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test(arguments: [false, true])
func chatListJSONPreservesEmptyTitle(hasJoinDate: Bool) async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let db = try Connection(path)
  try configureEmptyChatTitle(db, hasJoinDate: hasJoinDate)
  let values = ParsedValues(positional: [], options: ["db": [path]], flags: ["jsonOutput"])
  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      contactResolverFactory: { NoOpContactResolver(contactsUnavailable: true) }
    )
  }
  let line = try #require(output.split(separator: "\n").first)
  let chat = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  #expect(chat["name"] as? String == "+123")
  #expect(chat["display_name"] as? String == "")
  #expect(chat["identifier"] as? String == "+123")
}

@Test(arguments: [false, true])
func rpcChatListPreservesEmptyTitle(hasJoinDate: Bool) async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  try store.withConnection { db in
    try configureEmptyChatTitle(db, hasJoinDate: hasJoinDate)
  }
  // Reopen after schema changes so the query chooses the matching date layout.
  let refreshed = try store.withConnection { db in
    try MessageStore(connection: db, path: ":memory:")
  }
  let output = TestRPCOutput()
  let server = RPCServer(
    store: refreshed, verbose: false, output: output,
    contactResolver: NoOpContactResolver(contactsUnavailable: true)
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"chats.list","params":{"limit":1}}"#
  )
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  let chat = try #require((result["chats"] as? [[String: Any]])?.first)
  #expect(chat["name"] as? String == "+123")
  #expect(chat["display_name"] as? String == "")
  #expect(chat["identifier"] as? String == "+123")
}

private func configureEmptyChatTitle(_ db: Connection, hasJoinDate: Bool) throws {
  try db.run("UPDATE chat SET display_name = '' WHERE ROWID = 1")
  if hasJoinDate {
    try db.execute(
      """
      ALTER TABLE chat_message_join ADD COLUMN message_date INTEGER;
      UPDATE chat_message_join SET message_date = 100;
      """
    )
  }
}
