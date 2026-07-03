import Foundation
import SQLite
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

  let unreadObject = try JSONSerialization.jsonObject(
    with: try JSONEncoder().encode(unreadPayload)
  ) as? [String: Any]
  let readObject = try JSONSerialization.jsonObject(
    with: try JSONEncoder().encode(readPayload)
  ) as? [String: Any]
  let outboundObject = try JSONSerialization.jsonObject(
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
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeChatRouting: true,
      includeChatHandleJoin: true,
      includeReadState: true
    )
  )

  let now = Date()
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
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
    VALUES (5, 1, 'hello', ?, 0, 'iMessage', 0, 0)
    """,
    CommandTestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10,"unread_only":true}}"#
  await server.handleLineForTesting(line)

  let result = output.responses[0]["result"] as? [String: Any]
  let chats = result?["chats"] as? [[String: Any]] ?? []
  #expect(chats.count == 1)
  #expect(chats[0]["unread_count"] as? Int == 1)
}

@Test
func rpcMessagesHistoryIncludesInboundReadState() async throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeChatRouting: true,
      includeChatHandleJoin: true,
      includeReadState: true
    )
  )

  let now = Date()
  let readAt = Date(timeIntervalSince1970: 1_700_000_000)
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
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
    VALUES
      (5, 1, 'unread', ?, 0, 'iMessage', 0, 0),
      (6, 1, 'read', ?, 0, 'iMessage', 1, ?)
    """,
    CommandTestDatabase.appleEpoch(now),
    CommandTestDatabase.appleEpoch(now),
    CommandTestDatabase.appleEpoch(readAt)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5), (1, 6)")

  let store = try MessageStore(connection: db, path: ":memory:")
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
