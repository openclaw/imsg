import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesByChatUsesAttributedBodyFallback() throws {
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
  let body = Blob(bytes: Array(archivedAttributedBody("fallback text")))
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
  #expect(messages.first?.text == "fallback text")
}

@Test
func messagesByChatUsesLengthPrefixedAttributedBodyFallback() throws {
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
  let text = "length prefixed"
  let body = Blob(bytes: Array(archivedAttributedBody(text)))
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
  #expect(messages.first?.text == "length prefixed")
}

@Test
func messagesByChatUsesUTF16LittleEndianAttributedBodyFallback() throws {
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
  var bodyData = Data([0xff, 0xfe])
  let bodyText = "hello 🌤️"
  let encoded = try #require(bodyText.data(using: .utf16LittleEndian))
  bodyData.append(encoded)
  let body = Blob(bytes: [UInt8](bodyData))
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;-;+123', 'Direct Chat', 'iMessage')
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
  #expect(messages.first?.text == bodyText)
}

@Test
func messagesAfterUsesAttributedBodyFallback() throws {
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
  let body = Blob(bytes: Array(archivedAttributedBody("new text")))
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
  let messages = try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "new text")
}

@Test
func searchMessagesMatchesPlainAndAttributedBodies() throws {
  let db = try makeAttributedBodySearchDatabase()
  let now = Date()
  try insertSearchMessage(
    db,
    rowID: 1,
    text: "plain searchable body",
    attributedText: nil,
    date: now
  )
  try insertSearchMessage(
    db,
    rowID: 2,
    text: nil,
    attributedText: "attributed searchable body",
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "searchable", match: "contains", limit: 10)

  #expect(messages.map(\.rowID) == [2, 1])
  #expect(messages.map(\.text) == ["attributed searchable body", "plain searchable body"])
}

@Test
func searchMessagesExactlyMatchesPlainAndAttributedBodiesCaseInsensitively() throws {
  let db = try makeAttributedBodySearchDatabase()
  let now = Date()
  try insertSearchMessage(
    db,
    rowID: 1,
    text: "Exact Search Body",
    attributedText: nil,
    date: now
  )
  try insertSearchMessage(
    db,
    rowID: 2,
    text: nil,
    attributedText: "Exact Search Body",
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "exact search body", match: "exact", limit: 10)

  #expect(messages.map(\.rowID) == [2, 1])
}

@Test
func searchMessagesFillsLimitPastNonmatchingAttributedBodies() throws {
  let db = try makeAttributedBodySearchDatabase()
  let now = Date()
  try insertSearchMessage(
    db,
    rowID: 1,
    text: nil,
    attributedText: "matching attributed body",
    date: now
  )
  try insertSearchMessage(
    db,
    rowID: 2,
    text: nil,
    attributedText: "newer unrelated body",
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.searchMessages(query: "matching", match: "contains", limit: 1)

  #expect(messages.map(\.rowID) == [1])
}

private func makeAttributedBodySearchDatabase() throws -> Connection {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: .init(includeAttributedBody: true)
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  return db
}

private func insertSearchMessage(
  _ db: Connection,
  rowID: Int64,
  text: String?,
  attributedText: String?,
  date: Date
) throws {
  let body: Blob? = attributedText.map {
    Blob(bytes: Array(archivedAttributedBody($0)))
  }
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (?, 1, ?, ?, ?, 0, 'iMessage')
    """,
    rowID,
    text,
    body,
    TestDatabase.appleEpoch(date)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", rowID)
}
