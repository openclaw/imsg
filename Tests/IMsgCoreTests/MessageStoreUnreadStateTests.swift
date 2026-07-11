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
func listChatsCountsConsecutiveSplitURLPreviewsAsOneUnreadMessage() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true,
      includeReadState: true
    )
  )
  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+111', 'iMessage;-;+111', 'Links', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service, is_read, date_read
    )
    VALUES
      (1, 1, 'See https://one.example and https://two.example', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage', 0, 0),
      (2, 1, 'https://one.example', 'first-preview-guid', NULL, NULL, ?, ?, 0, 'iMessage', 0, 0),
      (3, 1, 'https://two.example', 'second-preview-guid', NULL, NULL, ?, ?, 0, 'iMessage', 0, 0)
    """,
    TestDatabase.appleEpoch(now),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(1)),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(2))
  )
  try db.run(
    "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2), (1, 3)"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.listChats(limit: 1).first?.unreadCount == 1)
  #expect(try store.listChats(limit: 1, unreadOnly: true).first?.unreadCount == 1)
}

@Test
func listChatsUsesTextRowReadStateForSplitURLPreview() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true,
      includeReadState: true
    )
  )
  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+111', 'iMessage;-;+111', 'Links', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service, is_read, date_read
    )
    VALUES
      (1, 1, 'See https://example.com', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage', 1, ?),
      (2, 1, 'https://example.com', 'preview-guid', NULL, NULL, ?, ?, 0, 'iMessage', 0, 0)
    """,
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.listChats(limit: 1).first?.unreadCount == 0)
  #expect(try store.listChats(limit: 1, unreadOnly: true).isEmpty)
}

@Test
func listChatsDoesNotCoalesceURLPreviewAcrossInterveningMessage() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true,
      includeReadState: true
    )
  )
  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+111', 'iMessage;-;+111', 'Links', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service, is_read, date_read
    )
    VALUES
      (1, 1, 'See https://example.com', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage', 0, 0),
      (2, 1, 'intervening', 'middle-guid', NULL, NULL, NULL, ?, 0, 'iMessage', 1, ?),
      (3, 1, 'https://example.com', 'preview-guid', NULL, NULL, ?, ?, 0, 'iMessage', 0, 0)
    """,
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now.addingTimeInterval(1)),
    TestDatabase.appleEpoch(now.addingTimeInterval(1)),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(2))
  )
  try db.run(
    "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2), (1, 3)"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.listChats(limit: 1).first?.unreadCount == 2)
}

@Test
func listChatsUnreadOnlyContinuesPastFalseURLPreviewCandidate() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true,
      includeReadState: true
    )
  )
  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Older Unread', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Newer Read Link', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, balloon_bundle_id, date, is_from_me, service,
      is_read, date_read
    )
    VALUES
      (1, 1, 'actually unread', 'unread-guid', NULL, ?, 0, 'iMessage', 0, 0),
      (2, 2, 'See https://example.com', 'text-guid', NULL, ?, 0, 'iMessage', 1, ?),
      (3, 2, 'https://example.com', 'preview-guid', ?, ?, 0, 'iMessage', 0, 0)
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-60)),
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now),
    MessageStore.urlPreviewBalloonBundleID,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run(
    "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (2, 2), (2, 3)"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 1, unreadOnly: true)
  #expect(chats.map(\.id) == [1])
  #expect(chats.first?.unreadCount == 1)
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
func listChatsUnreadOnlyFiltersBeforeApplyingLimit() throws {
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
      (1, '+111', 'iMessage;-;+111', 'Older Unread', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Newer Read', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read, date_read)
    VALUES
      (1, 1, 'unread', ?, 0, 'iMessage', 0, 0),
      (2, 2, 'read', ?, 0, 'iMessage', 1, ?)
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-60)),
    TestDatabase.appleEpoch(now),
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (2, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 1, unreadOnly: true)
  #expect(chats.map(\.id) == [1])
}

@Test
func listChatsOmitsUnreadStateWhenSchemaDoesNotSupportIt() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+111', 'iMessage;-;+111', 'Legacy Chat', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (1, NULL, 'hello', 1, 0, 'iMessage')
    """
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(store.supportsUnreadState == false)
  #expect(try store.listChats(limit: 1).first?.unreadCount == nil)
  #expect(throws: (any Error).self) {
    try store.listChats(limit: 1, unreadOnly: true)
  }
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

@Test
func messagesExposeReadFlagWhenDateReadColumnIsUnavailable() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  try db.execute("ALTER TABLE message ADD COLUMN is_read INTEGER;")
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read)
    VALUES (1, 1, 'read inbound', 1, 0, 'iMessage', 1)
    """
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let message = try #require(store.messages(chatID: 1, limit: 1).first)
  #expect(message.isRead == true)
  #expect(message.dateRead == nil)
}
