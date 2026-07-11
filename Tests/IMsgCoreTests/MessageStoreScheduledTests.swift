import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func scheduledMessagesListsOnlyFutureOutboundRowsInChronologicalOrder() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeAttributedBody = true
  options.includeReactionColumns = true
  options.includeScheduleColumns = true
  try MessageDatabaseFixture.createSchema(db, options: options)
  let asOf = Date(timeIntervalSinceReferenceDate: 800_000_000)

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Alice', 'iMessage')
    """)

  try insertScheduledMessage(
    db, rowID: 4, guid: "later", text: "two hours", date: asOf.addingTimeInterval(7200))
  try insertScheduledMessage(
    db, rowID: 3, guid: "same-time-high", text: "one hour b",
    date: asOf.addingTimeInterval(3600))
  try insertScheduledMessage(
    db, rowID: 2, guid: "same-time-low", text: "one hour a",
    date: asOf.addingTimeInterval(3600))
  try insertScheduledMessage(
    db, rowID: 1, guid: "past", text: "past", date: asOf.addingTimeInterval(-60))
  try insertScheduledMessage(
    db, rowID: 5, guid: "incoming", text: "incoming",
    date: asOf.addingTimeInterval(1800), isFromMe: false)
  try insertScheduledMessage(
    db, rowID: 6, guid: "ordinary", text: "ordinary",
    date: asOf.addingTimeInterval(1800), scheduleType: 0, scheduleState: 0)
  let attributedText = "body from attributed data"
  let attributedBody: [UInt8] =
    [0x01, 0x2b, UInt8(attributedText.utf8.count)] + Array(attributedText.utf8) + [0x86, 0x84]
  try db.run(
    """
    INSERT INTO message(
      ROWID, guid, handle_id, text, attributedBody, schedule_type, schedule_state,
      date, is_from_me, service
    ) VALUES (7, 'attributed', 1, NULL, ?, 2, 1, ?, 1, 'iMessage')
    """,
    Blob(bytes: attributedBody),
    MessageStore.appleEpoch(asOf.addingTimeInterval(900))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 7)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.scheduledMessages(limit: 10, asOf: asOf)

  #expect(messages.map(\.guid) == ["attributed", "same-time-low", "same-time-high", "later"])
  #expect(messages.first?.text == attributedText)
  #expect(messages.first?.chatGUID == "iMessage;-;+123")
  #expect(messages.first?.scheduleType == 2)
  #expect(messages.first?.scheduleState == 1)
  #expect(try store.scheduledMessages(limit: 1, asOf: asOf).map(\.guid) == ["attributed"])
}

@Test
func scheduledMessagesRejectsUnsupportedSchemaAndInvalidLimits() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(store.supportsScheduledMessages == false)
  #expect(throws: ScheduledMessagesError.unsupportedSchema) {
    try store.scheduledMessages()
  }

  let scheduledDB = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeScheduleColumns = true
  try MessageDatabaseFixture.createSchema(scheduledDB, options: options)
  let scheduledStore = try MessageStore(connection: scheduledDB, path: ":memory:")
  #expect(throws: ScheduledMessagesError.invalidLimit) {
    try scheduledStore.scheduledMessages(limit: 0)
  }
}

private func insertScheduledMessage(
  _ db: Connection,
  rowID: Int64,
  guid: String,
  text: String,
  date: Date,
  isFromMe: Bool = true,
  scheduleType: Int = 2,
  scheduleState: Int = 1
) throws {
  try db.run(
    """
    INSERT INTO message(
      ROWID, guid, handle_id, text, schedule_type, schedule_state, date, is_from_me, service
    ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, 'iMessage')
    """,
    rowID,
    guid,
    text,
    scheduleType,
    scheduleState,
    MessageStore.appleEpoch(date),
    isFromMe ? 1 : 0
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", rowID)
}
