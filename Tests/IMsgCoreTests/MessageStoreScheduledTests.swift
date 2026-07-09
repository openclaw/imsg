import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func scheduledMessagesListsRowsWithScheduleColumns() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  options.includeScheduleColumns = true
  try MessageDatabaseFixture.createSchema(db, options: options)
  let scheduledDate = Date().addingTimeInterval(3600)
  let scheduledAt = MessageStore.appleEpoch(scheduledDate)
  let deliveredAt = MessageStore.appleEpoch(Date().addingTimeInterval(-60))

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage')
    """)
  try db.run(
    """
    INSERT INTO message(ROWID, guid, handle_id, text, schedule_type, schedule_state, date, is_from_me, service)
    VALUES (1, 'scheduled-guid', 1, 'later', 2, 1, ?, 1, 'iMessage')
    """,
    scheduledAt
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run(
    """
    INSERT INTO message(ROWID, guid, handle_id, text, schedule_type, schedule_state, date, is_from_me, service)
    VALUES (2, 'delivered-guid', 1, 'already sent', 2, 2, ?, 1, 'iMessage')
    """,
    deliveredAt
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.scheduledMessages()

  #expect(messages.count == 1)
  #expect(messages[0].guid == "scheduled-guid")
  #expect(messages[0].chatGUID == "iMessage;-;+123")
  #expect(messages[0].scheduleType == 2)
  #expect(messages[0].scheduleState == 1)
  let resolved = try store.scheduledMessage(
    chatGUID: "iMessage;-;+123",
    scheduledAt: scheduledDate
  )
  #expect(resolved?.guid == "scheduled-guid")
}

@Test
func scheduledMessagesReturnsEmptyWhenColumnsMissing() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(try store.scheduledMessages().isEmpty)
}
