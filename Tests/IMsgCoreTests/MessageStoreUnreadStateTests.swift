import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func listChatsCountsUnreadInboundMessages() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )

  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Unread Chat', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Read Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (2, 2)")

  let unreadDate = TestDatabase.appleEpoch(now.addingTimeInterval(-100))
  let readDate = TestDatabase.appleEpoch(now.addingTimeInterval(-50))
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, date, is_from_me, service, is_read, date_read
    )
    VALUES
      (1, 1, 'unread one', ?, 0, 'iMessage', 0, 0),
      (2, 1, 'unread two', ?, 0, 'iMessage', 0, 0),
      (3, 1, 'read inbound', ?, 0, 'iMessage', 1, ?),
      (4, 1, 'outbound', ?, 1, 'iMessage', 0, 0),
      (5, 2, 'all read', ?, 0, 'iMessage', 1, ?)
    """,
    unreadDate,
    unreadDate,
    readDate,
    readDate,
    readDate,
    readDate,
    readDate
  )
  try db.run(
    """
    INSERT INTO chat_message_join(chat_id, message_id)
    VALUES (1, 1), (1, 2), (1, 3), (1, 4), (2, 5)
    """
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 10)
  #expect(chats.count == 2)
  let unreadChat = chats.first { $0.identifier == "+111" }
  let readChat = chats.first { $0.identifier == "+222" }
  #expect(unreadChat?.unreadCount == 2)
  #expect(readChat?.unreadCount == 0)
}

@Test
func listChatsUnreadOnlyFiltersChatsWithUnreadInboundMessages() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )

  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Unread Chat', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Read Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (2, 2)")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
    VALUES
      (1, 1, 'unread', ?, 0, 'iMessage', 0, 0),
      (2, 2, 'read', ?, 0, 'iMessage', 1, ?)
    """,
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (2, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 10, unreadOnly: true)
  #expect(chats.count == 1)
  #expect(chats.first?.identifier == "+111")
  #expect(chats.first?.unreadCount == 1)
}

@Test
func messagesExposeInboundReadState() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )

  let now = Date()
  let readAt = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'Me')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
    VALUES
      (1, 1, 'unread inbound', ?, 0, 'iMessage', 0, 0),
      (2, 1, 'read inbound', ?, 0, 'iMessage', 1, ?),
      (3, 2, 'outbound', ?, 1, 'iMessage', 0, 0)
    """,
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(readAt),
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2), (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 3)

  let unread = messages.first { $0.rowID == 1 }
  let read = messages.first { $0.rowID == 2 }
  let outbound = messages.first { $0.rowID == 3 }
  #expect(unread?.isRead == false)
  #expect(unread?.dateRead == nil)
  #expect(read?.isRead == true)
  #expect(read?.dateRead == readAt)
  #expect(outbound?.isRead == nil)
  #expect(outbound?.dateRead == nil)
}
