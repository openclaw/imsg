import Foundation
import SQLite
import Testing

@testable import IMsgCore

private func makeInMemoryMessageDB(
  includeThreadOriginatorGUID: Bool = false,
  includeBalloonBundleID: Bool = false
) throws -> Connection {
  let db = try Connection(.inMemory)
  let threadOriginatorColumn = includeThreadOriginatorGUID ? "thread_originator_guid TEXT," : ""
  let balloonColumn = includeBalloonBundleID ? "balloon_bundle_id TEXT," : ""
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      guid TEXT,
      associated_message_guid TEXT,
      associated_message_type INTEGER,
      \(threadOriginatorColumn)
      \(balloonColumn)
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
  return db
}

@Test
func chatInfoReturnsMetadata() throws {
  let store = try TestDatabase.makeStore()
  let info = try store.chatInfo(chatID: 1)
  #expect(info?.identifier == "+123")
  #expect(info?.guid == "iMessage;+;chat123")
  #expect(info?.name == "Test Chat")
  #expect(info?.service == "iMessage")
  #expect(info?.accountID == "iMessage;+;me@icloud.com")
  #expect(info?.accountLogin == "me@icloud.com")
  #expect(info?.lastAddressedHandle == "+15551234567")
}

@Test
func sqlRowDecodingThrowsWhenRequiredAliasIsMissing() throws {
  let db = try Connection(.inMemory)
  let store = try MessageStore(connection: db, path: ":memory:")
  try store.withConnection { db in
    let rows = try db.prepareRowIterator("SELECT 1 AS actual_value")
    let row = try #require(try rows.failableNext())
    #expect(throws: (any Error).self) {
      _ = try store.int64Value(row, "expected_value")
    }
  }
}

@Test
func participantsReturnsUniqueHandles() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      chat_identifier TEXT,
      guid TEXT,
      display_name TEXT,
      service_name TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2), (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let participants = try store.participants(chatID: 1)
  #expect(participants.count == 2)
  #expect(participants.contains("+123"))
  #expect(participants.contains("me@icloud.com"))
}

@Test
func messagesByChatReturnsMessages() throws {
  let store = try TestDatabase.makeStore()
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 3)
  #expect(messages[1].isFromMe)
  #expect(messages[0].attachmentsCount == 0)
}

@Test
func messagesByChatAppliesDateFilterBeforeLimit() throws {
  let store = try TestDatabase.makeStore()
  let all = try store.messages(chatID: 1, limit: 10)
  let target = all.first { $0.rowID == 2 }
  #expect(target != nil)

  // Build a tight window around message 2's date so the filter matches it but not the newest message.
  guard let target else { return }
  let filter = MessageFilter(
    startDate: target.date.addingTimeInterval(-1),
    endDate: target.date.addingTimeInterval(1)
  )
  let filtered = try store.messages(chatID: 1, limit: 1, filter: filter)
  #expect(filtered.count == 1)
  #expect(filtered.first?.rowID == 2)
}

@Test
func messagesByChatAppliesParticipantFilterBeforeLimit() throws {
  let store = try TestDatabase.makeStore()

  // Insert a newer "from me" message so limit=1 would pick it unless filtering happens in SQL.
  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (4, 2, 'newest from me', ?, 1, 'iMessage')
      """,
      TestDatabase.appleEpoch(Date().addingTimeInterval(5))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 4)")
  }

  let filter = MessageFilter(participants: ["+123"])
  let filtered = try store.messages(chatID: 1, limit: 1, filter: filter)
  #expect(filtered.count == 1)
  #expect(filtered.first?.sender == "+123")
}

@Test
func messagesAfterReturnsMessages() throws {
  let store = try TestDatabase.makeStore()
  let messages = try store.messagesAfter(afterRowID: 1, chatID: nil, limit: 10)
  #expect(messages.count == 2)
  #expect(messages.first?.rowID == 2)
}

@Test
func messagesAfterDeduplicatesURLBalloonsAcrossPolls() throws {
  let db = try makeInMemoryMessageDB(includeBalloonBundleID: true)
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (1, 1, 'https://example.com', 'msg-guid-1', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let firstPoll = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  #expect(firstPoll.map(\.rowID) == [1])
  #expect(firstPoll.first?.balloonBundleID == "com.apple.messages.URLBalloonProvider")

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (2, 1, 'https://example.com', 'msg-guid-2', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(30))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let secondPoll = try store.messagesAfter(afterRowID: 1, chatID: 1, limit: 10)
  #expect(secondPoll.isEmpty)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (3, 1, 'https://example.com', 'msg-guid-3', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(5 * 60))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

  let thirdPoll = try store.messagesAfter(afterRowID: 1, chatID: 1, limit: 10)
  #expect(thirdPoll.map(\.rowID) == [3])
  #expect(thirdPoll.first?.balloonBundleID == "com.apple.messages.URLBalloonProvider")
}

@Test
func messagesByChatPreservesBalloonBundleID() throws {
  let db = try makeInMemoryMessageDB(includeBalloonBundleID: true)
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (1, 1, 'https://example.com', 'msg-guid-1', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.balloonBundleID == "com.apple.messages.URLBalloonProvider")
}

@Test
func searchMessagesPreservesBalloonBundleID() throws {
  let db = try makeInMemoryMessageDB(includeBalloonBundleID: true)
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (1, 1, 'https://example.com/search', 'msg-guid-1', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "example.com/search", match: "contains", limit: 10)
  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.balloonBundleID == "com.apple.messages.URLBalloonProvider")
}

@Test
func messagesAfterURLBalloonDedupingDoesNotCrossChats() throws {
  let db = try makeInMemoryMessageDB(includeBalloonBundleID: true)
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (1, 1, 'https://example.com', 'msg-guid-1', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, date, is_from_me, service
    )
    VALUES (2, 1, 'https://example.com', 'msg-guid-2', NULL, 0, 'com.apple.messages.URLBalloonProvider', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(15))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(messages.map(\.rowID) == [1, 2])
}

@Test
func messagesAfterExcludesReactionRows() throws {
  let db = try makeInMemoryMessageDB()

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'hello', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 1, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2002, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 1, 'reply', 'msg-guid-3', 'p:0/msg-guid-1', 1000, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(2))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let rowIDs = messages.map { $0.rowID }
  #expect(messages.count == 2)
  #expect(rowIDs.contains(1))
  #expect(rowIDs.contains(3))
  #expect(rowIDs.contains(2) == false)
}

@Test
func messagesExcludeReactionRows() throws {
  let db = try makeInMemoryMessageDB()

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'hello', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 1, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2001, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.rowID == 1)
}

@Test
func messagesExposeReplyToGuid() throws {
  let db = try makeInMemoryMessageDB()

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'base', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 1, 'reply', 'msg-guid-2', 'p:0/msg-guid-1', 1000, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reply = messages.first { $0.rowID == 2 }
  #expect(reply?.guid == "msg-guid-2")
  #expect(reply?.replyToGUID == "msg-guid-1")
}

@Test
func messagesReplyToGuidHandlesNoPrefix() throws {
  let db = try makeInMemoryMessageDB()

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'base', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 1, 'reply', 'msg-guid-2', 'msg-guid-1', 1000, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reply = messages.first { $0.rowID == 2 }
  #expect(reply?.replyToGUID == "msg-guid-1")
}

@Test
func messagesExposeThreadOriginatorGuidWhenAvailable() throws {
  let db = try makeInMemoryMessageDB(includeThreadOriginatorGUID: true)

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      thread_originator_guid, date, is_from_me, service
    )
    VALUES (1, 1, 'hello', 'msg-guid-1', NULL, 0, 'thread-guid-1', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let message = messages.first { $0.rowID == 1 }
  #expect(message?.threadOriginatorGUID == "thread-guid-1")
}

@Test
func attachmentsByMessageReturnsMetadata() throws {
  let store = try TestDatabase.makeStore()
  let attachments = try store.attachments(for: 2)
  #expect(attachments.count == 1)
  #expect(attachments.first?.mimeType == "application/octet-stream")
}

@Test
func attachmentsByMessagesReturnsMetadataByMessageID() throws {
  let store = try TestDatabase.makeStore()
  let attachmentsByMessageID = try store.attachments(for: [1, 2, 2, 3])

  #expect(attachmentsByMessageID[1]?.isEmpty != false)
  #expect(attachmentsByMessageID[2]?.count == 1)
  #expect(attachmentsByMessageID[2]?.first?.mimeType == "application/octet-stream")
  #expect(attachmentsByMessageID[3]?.isEmpty != false)
}

@Test
func longRepeatedPatternMessage() throws {
  // Test the exact pattern that causes crashes: repeated "aaaaaaaaaaaa " pattern
  // This reproduces the UInt8 overflow bug when segment.count > 256
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      chat_identifier TEXT,
      guid TEXT,
      display_name TEXT,
      service_name TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    """
    CREATE TABLE message_attachment_join (
      message_id INTEGER,
      attachment_id INTEGER
    );
    """
  )

  let now = Date()
  // Create message with repeated pattern like "aaaaaaaaaaaa aaaaaaaaaaaa ..."
  // This pattern triggers the UInt8 overflow bug in TypedStreamParser when segment > 256 bytes
  let pattern = "aaaaaaaaaaaa "
  // Creates a message > 1300 bytes
  let longText = String(repeating: pattern, count: 100)
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array(longText.utf8) + [0x86, 0x84]
  let body = Blob(bytes: bodyBytes)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
    """,
    body,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == longText)
  #expect(messages.first?.text.count == longText.count)
}
