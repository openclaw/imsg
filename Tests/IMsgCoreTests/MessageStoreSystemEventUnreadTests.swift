import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func listChatsIgnoresUnreadSystemEvents() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )
  try db.execute("ALTER TABLE message ADD COLUMN item_type INTEGER;")

  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+111', 'iMessage;-;+111', 'Ghost Rows', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, date, is_from_me, service, is_read, date_read, item_type
    )
    VALUES
      (1, 1, NULL, ?, 0, 'iMessage', 0, 0, 4),
      (2, 1, '', ?, 0, 'iMessage', 0, 0, 2),
      (3, 1, 'visible unread', ?, 0, 'iMessage', 0, 0, 0),
      (4, 1, '', ?, 0, 'iMessage', 0, 0, 0),
      (5, 1, '', ?, 0, 'iMessage', 0, 0, 3)
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-4)),
    TestDatabase.appleEpoch(now.addingTimeInterval(-3)),
    TestDatabase.appleEpoch(now.addingTimeInterval(-2)),
    TestDatabase.appleEpoch(now.addingTimeInterval(-1)),
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO chat_message_join(chat_id, message_id)
    VALUES (1, 1), (1, 2), (1, 3), (1, 4), (1, 5)
    """
  )
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name)
    VALUES
      (1, 'photo.heic', 'photo.heic'),
      (2, 'group-photo.heic', 'GroupPhotoImage')
    """
  )
  try db.run(
    """
    INSERT INTO message_attachment_join(message_id, attachment_id)
    VALUES (4, 1), (5, 2)
    """
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.listChats(limit: 1).first?.unreadCount == 2)
}

@Test
func listChatsUnreadOnlySkipsChatsWithOnlySystemEvents() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )
  try db.execute("ALTER TABLE message ADD COLUMN item_type INTEGER;")

  let now = Date()
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Older Unread', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Newer Ghost', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, date, is_from_me, service, is_read, date_read, item_type
    )
    VALUES
      (1, 1, 'actually unread', ?, 0, 'iMessage', 0, 0, 0),
      (2, 2, '', ?, 0, 'iMessage', 0, 0, 4),
      (3, 2, '', ?, 0, 'iMessage', 0, 0, 3)
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-60)),
    TestDatabase.appleEpoch(now.addingTimeInterval(-1)),
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (2, 2), (2, 3)"
  )
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name)
    VALUES (1, 'group-photo.heic', 'GroupPhotoImage')
    """
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (3, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 1, unreadOnly: true)
  #expect(chats.map(\.id) == [1])
  #expect(chats.first?.unreadCount == 1)
}
