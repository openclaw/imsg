import Foundation
import SQLite
import Testing

@testable import IMsgCore

private func makeMessageStatsFixture() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true
    )
  )
  let base = TestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_735_691_400))

  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111'), (2, '+222')")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Alpha', 'iMessage'),
      (2, '+222', 'SMS;-;+222', 'Beta', 'SMS'),
      (3, 'empty', 'iMessage;-;empty', 'Empty', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES
      (1, 1, 'See https://example.com', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage'),
      (2, 1, 'https://example.com', 'preview-guid', NULL, NULL, ?, ?, 0, 'iMessage'),
      (3, 1, 'normal inbound', 'normal-guid', NULL, NULL, NULL, ?, 0, 'iMessage'),
      (4, 1, 'outbound', 'outbound-guid', NULL, NULL, NULL, ?, 1, 'iMessage'),
      (5, 1, 'Liked outbound', 'reaction-add', 'p:0/outbound-guid', 2000, NULL, ?, 0, 'iMessage'),
      (6, 1, 'Removed like', 'reaction-remove', 'p:0/outbound-guid', 3000, NULL, ?, 0, 'iMessage'),
      (7, 1, 'https://standalone.test', 'standalone-preview', NULL, NULL, ?, ?, 0, 'iMessage'),
      (8, 2, 'sms inbound', 'sms-in', NULL, NULL, NULL, ?, 0, 'SMS'),
      (9, 2, 'sms outbound', 'sms-out', NULL, NULL, NULL, ?, 1, 'SMS')
    """,
    base,
    MessageStore.urlPreviewBalloonBundleID,
    base + 1_000_000_000,
    base + 2_000_000_000,
    base + 3_000_000_000,
    base + 4_000_000_000,
    base + 5_000_000_000,
    MessageStore.urlPreviewBalloonBundleID,
    base + 6_000_000_000,
    base + 7_000_000_000,
    base + 8_000_000_000
  )
  try db.run(
    """
    INSERT INTO chat_message_join(chat_id, message_id)
    VALUES
      (1, 1), (1, 2), (1, 3), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7),
      (2, 8), (2, 9)
    """
  )
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES
      (1, '/tmp/a.jpg', 'a.jpg', 'public.jpeg', 'image/jpeg', 10, 0),
      (2, '/tmp/b.mov', 'b.mov', 'com.apple.quicktime-movie', 'video/quicktime', 20, 0)
    """
  )
  try db.run(
    """
    INSERT INTO message_attachment_join(message_id, attachment_id)
    VALUES (3, 1), (3, 1), (4, 2)
    """
  )
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func messageStatsAggregatesLogicalMessagesAndDistinctMedia() throws {
  let store = try makeMessageStatsFixture()
  let stats = try store.messageStats(includeMedia: true, timeZoneIdentifier: "UTC")

  #expect(stats.totalMessages == 6)
  #expect(stats.sentMessages == 2)
  #expect(stats.receivedMessages == 4)
  #expect(stats.sentMessages + stats.receivedMessages == stats.totalMessages)
  #expect(stats.timeZone == "GMT")
  #expect(stats.chats.map(\.messageCount) == [4, 2])
  #expect(
    stats.senders == [
      SenderMessageStats(handle: "+111", messageCount: 3),
      SenderMessageStats(handle: "+222", messageCount: 1),
    ])
  #expect(
    stats.services == [
      ServiceMessageStats(service: "iMessage", messageCount: 4),
      ServiceMessageStats(service: "SMS", messageCount: 2),
    ])
  #expect(stats.dates == [DateMessageStats(date: "2025-01-01", messageCount: 6)])
  #expect(stats.media?.totalAttachments == 2)
  #expect(stats.media?.totalBytes == 30)
  #expect(stats.media?.chats.first?.chatID == 1)
  #expect(stats.media?.chats.first?.attachmentCount == 2)
}

@Test
func messageStatsScopesChatsAndUsesRequestedTimeZone() throws {
  let store = try makeMessageStatsFixture()

  let first = try store.messageStats(
    chatID: 1,
    includeMedia: true,
    timeZoneIdentifier: "America/Los_Angeles"
  )
  #expect(first.totalMessages == 4)
  #expect(first.chats.map(\.chatID) == [1])
  #expect(first.dates == [DateMessageStats(date: "2024-12-31", messageCount: 4)])
  #expect(first.media?.totalAttachments == 2)

  let second = try store.messageStats(chatID: 2, includeMedia: true, timeZoneIdentifier: "UTC")
  #expect(second.totalMessages == 2)
  #expect(second.media?.totalAttachments == 0)
  #expect(second.media?.totalBytes == 0)

  let empty = try store.messageStats(chatID: 3, timeZoneIdentifier: "UTC")
  #expect(empty.totalMessages == 0)
  #expect(empty.chats.isEmpty)
  #expect(empty.senders.isEmpty)
  #expect(empty.services.isEmpty)
  #expect(empty.dates.isEmpty)
}

@Test
func messageStatsRejectsInvalidScopeAndTimeZone() throws {
  let store = try makeMessageStatsFixture()

  #expect(throws: MessageStatsError.invalidChatID(0)) {
    try store.messageStats(chatID: 0)
  }
  #expect(throws: MessageStatsError.chatNotFound(999)) {
    try store.messageStats(chatID: 999)
  }
  #expect(throws: MessageStatsError.invalidTimeZone("Not/AZone")) {
    try store.messageStats(timeZoneIdentifier: "Not/AZone")
  }
}

@Test
func messageStatsKeepsNonReactionAssociatedRowsAndPreviewBoundary() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true
    )
  )
  let date = TestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_735_691_400))
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, '+111', 'iMessage;-;+111', 'Alpha', 'iMessage')"
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES
      (1, 1, 'See https://example.com', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage'),
      (2, 1, 'associated event', 'event-guid', 'text-guid', 2500, NULL, ?, 0, 'iMessage'),
      (3, 1, 'https://example.com', 'preview-guid', NULL, NULL, ?, ?, 0, 'iMessage')
    """,
    date,
    date + 1_000_000_000,
    MessageStore.urlPreviewBalloonBundleID,
    date + 2_000_000_000
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2), (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.messageStats(timeZoneIdentifier: "UTC").totalMessages == 3)
}

@Test
func messageStatsCoalescesConsecutivePreviewsLikeHistory() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeReactionColumns: true,
      includeBalloonBundleID: true
    )
  )
  let date = TestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_735_691_400))
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+111')")
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, '+111', 'iMessage;-;+111', 'Alpha', 'iMessage')"
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES
      (1, 1, 'See https://one.test and https://two.test', 'text-guid', NULL, NULL, NULL, ?, 0, 'iMessage'),
      (2, 1, 'https://one.test', 'preview-one', NULL, NULL, ?, ?, 0, 'iMessage'),
      (3, 1, 'https://two.test', 'preview-two', NULL, NULL, ?, ?, 0, 'iMessage')
    """,
    date,
    MessageStore.urlPreviewBalloonBundleID,
    date + 1_000_000_000,
    MessageStore.urlPreviewBalloonBundleID,
    date + 2_000_000_000
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1), (1, 2), (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.messageStats(timeZoneIdentifier: "UTC").totalMessages == 1)
}

@Test
func messageStatsOnlyRequiresMediaTablesWhenRequested() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, '+111', 'iMessage;-;+111', 'Alpha', 'iMessage')"
  )
  try db.execute("DROP TABLE message_attachment_join; DROP TABLE attachment;")
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(try store.messageStats(chatID: 1, includeMedia: false).totalMessages == 0)
  #expect(throws: MessageStatsError.mediaUnavailable) {
    try store.messageStats(chatID: 1, includeMedia: true)
  }
}
