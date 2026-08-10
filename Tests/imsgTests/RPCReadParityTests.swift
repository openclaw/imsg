import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcChatsListUsesCanonicalSingleParticipantContactFallback() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("DELETE FROM chat_handle_join WHERE handle_id = 2")
  }
  let output = TestRPCOutput()
  let resolver = MockContactResolver(names: ["+123": "Alice"])
  let server = RPCServer(store: store, verbose: false, output: output, contactResolver: resolver)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"direct","method":"chats.list","params":{"limit":1}}"#)

  let result = try #require(output.responses.first?["result"] as? [String: Any])
  let chat = try #require((result["chats"] as? [[String: Any]])?.first)
  #expect(chat["contact_name"] as? String == "Alice")
  #expect(chat["display_name"] as? String == "Direct Chat")
  #expect(chat["is_group"] as? Bool == false)
  #expect(chat["account_id"] as? String == "iMessage;+;me@icloud.com")
  #expect(chat["account_login"] as? String == "me@icloud.com")
  #expect(chat["last_addressed_handle"] as? String == "me@icloud.com")
}

@Test
func rpcMessagesSearchUsesDatabaseAndCanonicalMessagePayload() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let resolver = MockContactResolver(names: ["+123": "Alice"])
  let server = RPCServer(store: store, verbose: false, output: output, contactResolver: resolver)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"search","method":"messages.search","params":{"query":"HELLO","match":"exact","limit":1}}"#
  )

  let result = try #require(output.responses.first?["result"] as? [String: Any])
  let message = try #require((result["messages"] as? [[String: Any]])?.first)
  #expect((message["id"] as? NSNumber)?.int64Value == 5)
  #expect(message["text"] as? String == "hello")
  #expect(message["sender_name"] as? String == "Alice")
  #expect(message["chat_guid"] as? String == "iMessage;+;chat123")
  #expect((message["attachments"] as? [[String: Any]])?.isEmpty == true)
  #expect((message["reactions"] as? [[String: Any]])?.isEmpty == true)
}
