import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func chatPayloadIncludesUnreadCount() throws {
  let chat = Chat(
    id: 1,
    identifier: "+123",
    name: "Test",
    service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0),
    unreadCount: 3
  )
  let payload = ChatPayload(chat: chat)
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(object?["unread_count"] as? Int == 3)
}

@Test
func chatPayloadOmitsUnsupportedUnreadCount() throws {
  let chat = Chat(
    id: 1,
    identifier: "+123",
    name: "Test",
    service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0)
  )
  let object =
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(ChatPayload(chat: chat))
    ) as? [String: Any]
  #expect(object?["unread_count"] == nil)
}

@Test
func messagePayloadIncludesInboundReadState() throws {
  let readAt = Date(timeIntervalSince1970: 1_700_000_000)
  let unreadMessage = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "unread",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0,
    isRead: false
  )
  let readMessage = Message(
    rowID: 2,
    chatID: 1,
    sender: "+123",
    text: "read",
    date: Date(timeIntervalSince1970: 2),
    isFromMe: false,
    service: "iMessage",
    handleID: 1,
    attachmentsCount: 0,
    isRead: true,
    dateRead: readAt
  )
  let outboundMessage = Message(
    rowID: 3,
    chatID: 1,
    sender: "me@icloud.com",
    text: "sent",
    date: Date(timeIntervalSince1970: 3),
    isFromMe: true,
    service: "iMessage",
    handleID: 2,
    attachmentsCount: 0,
    isRead: false
  )

  let unreadPayload = MessagePayload(message: unreadMessage, attachments: [])
  let readPayload = MessagePayload(message: readMessage, attachments: [])
  let outboundPayload = MessagePayload(message: outboundMessage, attachments: [])

  let unreadObject =
    try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(unreadPayload)
    ) as? [String: Any]
  let readObject =
    try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(readPayload)
    ) as? [String: Any]
  let outboundObject =
    try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(outboundPayload)
    ) as? [String: Any]

  #expect(unreadObject?["is_read"] as? Bool == false)
  #expect(unreadObject?["date_read"] == nil)
  #expect(readObject?["is_read"] as? Bool == true)
  #expect(readObject?["date_read"] as? String != nil)
  #expect(outboundObject?["is_read"] == nil)
  #expect(outboundObject?["date_read"] == nil)
}

@Test
func rpcChatsListSupportsUnreadOnlyAndUnreadCount() async throws {
  let store = try UnreadStateCommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10,"unread_only":true}}"#
  await server.handleLineForTesting(line)

  let result = output.responses[0]["result"] as? [String: Any]
  let chats = result?["chats"] as? [[String: Any]] ?? []
  #expect(chats.count == 1)
  #expect(chats[0]["unread_count"] as? Int == 1)

  let camelLine =
    #"{"jsonrpc":"2.0","id":"2","method":"chats.list","params":{"limit":10,"unreadOnly":true}}"#
  await server.handleLineForTesting(camelLine)
  #expect(output.responses.count == 2)
  let camelResult = output.responses.last?["result"] as? [String: Any]
  let camelChats = camelResult?["chats"] as? [[String: Any]] ?? []
  #expect(camelChats.count == 1)
  #expect(camelChats[0]["unread_count"] as? Int == 1)
}

@Test
func rpcChatsListRejectsUnreadFilterWhenSchemaLacksReadState() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"unread_only":true}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32602)
}

@Test
func rpcMessagesHistoryIncludesInboundReadState() async throws {
  let store = try UnreadStateCommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.count == 2)
  let unread = messages.first { ($0["text"] as? String) == "unread" }
  let read = messages.first { ($0["text"] as? String) == "read" }
  #expect(unread?["is_read"] as? Bool == false)
  #expect(unread?["date_read"] == nil)
  #expect(read?["is_read"] as? Bool == true)
  #expect(read?["date_read"] as? String != nil)
}
