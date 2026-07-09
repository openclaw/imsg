import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageStatsAggregatesMessagesAndMedia() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  let firstDate = MessageStore.appleEpoch(Date(timeIntervalSince1970: 1_735_689_600))
  let secondDate = MessageStore.appleEpoch(Date(timeIntervalSince1970: 1_735_776_000))

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage'),
           (2, '+456', 'SMS;-;+456', 'Bob', 'SMS')
    """)
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (1, 1, 'hello', ?, 0, 'iMessage'),
           (2, 1, 'reply', ?, 1, 'iMessage'),
           (3, 2, 'sms', ?, 0, 'SMS')
    """,
    firstDate,
    firstDate,
    secondDate
  )
  try db.run(
    """
    INSERT INTO chat_message_join(chat_id, message_id)
    VALUES (1, 1), (1, 2), (2, 3)
    """)
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES (1, '/tmp/a.jpg', 'a.jpg', 'public.jpeg', 'image/jpeg', 100, 0),
           (2, '/tmp/b.mov', 'b.mov', 'com.apple.quicktime-movie', 'video/quicktime', 250, 0)
    """)
  try db.run(
    "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1), (3, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let stats = try store.messageStats(includeMedia: true)

  #expect(stats.totalMessages == 3)
  #expect(stats.chats.map(\.messageCount) == [2, 1])
  #expect(stats.handles.contains { $0.handle == "+123" && $0.messageCount == 1 })
  #expect(stats.handles.contains { $0.handle == "me" && $0.messageCount == 1 })
  #expect(stats.services.contains { $0.service == "iMessage" && $0.messageCount == 2 })
  #expect(
    stats.dates == [
      DateMessageStats(date: "2025-01-01", messageCount: 2),
      DateMessageStats(date: "2025-01-02", messageCount: 1),
    ])
  #expect(stats.media?.totalAttachments == 2)
  #expect(stats.media?.totalBytes == 350)
  #expect(stats.media?.types.first?.attachmentCount == 1)
}

@Test
func messageStatsCanFilterByChat() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  let date = MessageStore.appleEpoch(Date(timeIntervalSince1970: 1_735_689_600))

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage'),
           (2, '+456', 'SMS;-;+456', 'Bob', 'SMS')
    """)
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (1, 1, 'hello', ?, 0, 'iMessage'),
           (2, 2, 'sms', ?, 0, 'SMS')
    """,
    date,
    date
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (2, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let stats = try store.messageStats(chatID: 2)

  #expect(stats.totalMessages == 1)
  #expect(stats.chats.map(\.chatID) == [2])
  #expect(stats.handles == [HandleMessageStats(handle: "+456", messageCount: 1)])
}

@Test
func messageStatsExcludeReactionRows() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  try MessageDatabaseFixture.createSchema(db, options: options)
  let date = MessageStore.appleEpoch(Date(timeIntervalSince1970: 1_735_689_600))

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage')
    """)
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      date, is_from_me, service
    )
    VALUES (1, 1, 'hello', 'message-guid', NULL, NULL, ?, 0, 'iMessage'),
           (2, 1, 'Liked "hello"', 'reaction-guid', 'p:0/message-guid', 2000, ?, 0, 'iMessage')
    """,
    date,
    date
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let stats = try store.messageStats(chatID: 1)

  #expect(stats.totalMessages == 1)
  #expect(
    stats.chats == [
      ChatMessageStats(
        chatID: 1, identifier: "+123", name: "Alice", service: "iMessage", messageCount: 1)
    ])
  #expect(stats.handles == [HandleMessageStats(handle: "+123", messageCount: 1)])
  #expect(stats.services == [ServiceMessageStats(service: "iMessage", messageCount: 1)])
  #expect(stats.dates == [DateMessageStats(date: "2025-01-01", messageCount: 1)])
}
