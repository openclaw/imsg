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

@Test(arguments: [false, true])
func rpcChatsGetReturnsMetadataWithoutMessagesOrMutations(isGroup: Bool) async throws {
  let store =
    try isGroup
    ? CommandTestDatabase.makeStoreForRPC() : CommandTestDatabase.makeStoreForRPCDirectChat()
  // Neither chat listing nor message reads can work against this metadata-only fixture.
  try store.withConnection { db in
    try db.execute("DROP TABLE message; DROP TABLE chat_message_join;")
  }
  let changesBefore = try #require(
    try store.withConnection { try $0.scalar("SELECT total_changes()") as? Int64 })
  let output = TestRPCOutput()
  var mutationCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      mutationCalls += 1
      return options
    },
    invokeBridge: { _, _ in
      mutationCalls += 1
      return [:]
    },
    isBridgeReady: { false },
    startTyping: { _ in mutationCalls += 1 },
    stopTyping: { _ in mutationCalls += 1 },
    markAsRead: { _ in mutationCalls += 1 }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"metadata","method":"chats.get","params":{"chat_id":1}}"#)

  #expect(output.errors.isEmpty)
  #expect(output.responses.count == 1)
  #expect(output.responses.first?["id"] as? String == "metadata")
  let result = try #require(output.responses.first?["result"] as? [String: Any])
  #expect(
    Set(result.keys) == [
      "id", "identifier", "guid", "name", "service", "is_group", "participants",
      "account_id", "account_login", "last_addressed_handle",
    ])
  #expect(rpcTestInt64Value(result["id"]) == 1)
  #expect(result["identifier"] as? String == (isGroup ? "iMessage;+;chat123" : "+123"))
  #expect(result["guid"] as? String == (isGroup ? "iMessage;+;chat123" : "iMessage;-;+123"))
  #expect(result["name"] as? String == (isGroup ? "Group Chat" : "Direct Chat"))
  #expect(result["service"] as? String == "iMessage")
  #expect(result["is_group"] as? Bool == isGroup)
  #expect(result["participants"] as? [String] == ["+123", "me@icloud.com"])
  #expect(result["account_id"] as? String == "iMessage;+;me@icloud.com")
  #expect(result["account_login"] as? String == "me@icloud.com")
  #expect(result["last_addressed_handle"] as? String == "me@icloud.com")
  #expect(mutationCalls == 0)
  #expect(
    try store.withConnection { try $0.scalar("SELECT total_changes()") as? Int64 } == changesBefore)
}

@Test
func rpcChatsGetRejectsMissingMalformedAndUnknownIDs() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  let invalidParams = [
    (#"{}"#, "chat_id is required"),
    (#"{"chat_id":0}"#, "chat_id must be a positive integer"),
    (#"{"chat_id":-1}"#, "chat_id must be a positive integer"),
    (#"{"chat_id":"1"}"#, "chat_id must be an integer"),
    (#"{"chat_id":true}"#, "chat_id must be an integer"),
    (#"{"chat_id":1.5}"#, "chat_id must be an integer"),
    (#"{"chat_id":9223372036854775808}"#, "chat_id must be an integer"),
    (#"{"chat_id":null}"#, "chat_id must not be null"),
    (#"{"chat_id":[]}"#, "chat_id must be an integer"),
    (#"{"chat_id":{}}"#, "chat_id must be an integer"),
    (#"{"chatId":1}"#, "unknown chats.get param: chatId"),
    (#"{"chat_guid":"iMessage;+;chat123"}"#, "unknown chats.get param: chat_guid"),
    (#"{"chat_identifier":"iMessage;+;chat123"}"#, "unknown chats.get param: chat_identifier"),
    (#"{"chat_id":1,"limit":1}"#, "unknown chats.get param: limit"),
    (#"{"chat_id":999}"#, "Chat not found: 999"),
  ]

  for (params, detail) in invalidParams {
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"invalid","method":"chats.get","params":\#(params)}"#)
    let error = try #require(output.errors.last?["error"] as? [String: Any])
    #expect(rpcTestInt64Value(error["code"]) == -32602)
    #expect(error["data"] as? String == detail)
  }
  #expect(output.responses.isEmpty)
  #expect(output.errors.count == invalidParams.count)
}

@Test
func rpcChatsGetUsesDatabaseReadLaneWithoutBridge() throws {
  let descriptor = try #require(rpcMethodDescriptors.first { $0.names == ["chats.get"] })
  #expect(descriptor.route == .chatsGet)
  #expect(rpcRequestLane(for: "chats.get") == .read)
  #expect(descriptor.database == [.ready])
  #expect(descriptor.bridge == .none)
  #expect(!descriptor.macOSOnly)
  #expect(kSupportedRPCMethods.contains("chats.get"))
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
