import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum ReactionTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeConnection() throws -> Connection {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
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
    return db
  }

  static func seedBaseMessage(
    _ db: Connection,
    now: Date,
    messageID: Int64 = 1,
    guid: String = "msg-guid-1",
    text: String = "Hello world"
  ) throws {
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
      VALUES (1, '+123', 'Test Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (?, 1, ?, ?, NULL, 0, ?, 0, 'iMessage')
      """,
      messageID,
      text,
      guid,
      appleEpoch(now.addingTimeInterval(-600))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", messageID)
  }
}

@Test
func reactionsForMessageReturnsReactions() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)

  // Love reaction from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2000, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  // Like reaction from me
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 1, '', 'reaction-guid-2', 'p:0/msg-guid-1', 2001, ?, 1, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
  )
  // Laugh reaction from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (4, 2, '', 'reaction-guid-3', 'p:0/msg-guid-1', 2003, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-300))
  )
  // Custom emoji reaction (type 2006) from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (5, 2, 'Reacted 🎉 to "Hello world"', 'reaction-guid-4', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-200))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.count == 4)

  #expect(reactions[0].reactionType == .love)
  #expect(reactions[0].sender == "+456")
  #expect(reactions[0].isFromMe == false)

  #expect(reactions[1].reactionType == .like)
  #expect(reactions[1].isFromMe == true)

  #expect(reactions[2].reactionType == .laugh)
  #expect(reactions[2].sender == "+456")

  #expect(reactions[3].reactionType == .custom("🎉"))
  #expect(reactions[3].reactionType.emoji == "🎉")
  #expect(reactions[3].sender == "+456")
}

@Test
func bulkReactionsForMessagesGroupsByMessageID() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (10, 2, 'Second message', 'msg-guid-2', NULL, 0, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-550))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 10)")

  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2000, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 1, '', 'reaction-guid-2', 'msg-guid-2', 2001, ?, 1, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-450))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (4, 2, 'Removed a love', 'reaction-guid-3', 'p:0/msg-guid-1', 3000, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reactionsByMessageID = try store.reactions(for: messages)

  #expect(reactionsByMessageID[1]?.isEmpty != false)
  #expect(reactionsByMessageID[10]?.count == 1)
  #expect(reactionsByMessageID[10]?.first?.reactionType == .like)
  #expect(reactionsByMessageID[10]?.first?.isFromMe == true)
}

@Test
func bulkReactionsDoesNotAssumeReactionSharesTargetChat() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, display_name, service_name) VALUES (2, '+456', 'Other Chat', 'iMessage')"
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2000, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reactionsByMessageID = try store.reactions(for: messages)

  #expect(reactionsByMessageID[1]?.map(\.reactionType) == [.love])
}

@Test
func bulkReactionsReturnsEmptyWhenColumnsMissing() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  let store = try MessageStore(connection: db, path: ":memory:")
  let reactionsByMessageID = try store.reactions(for: [
    Message(
      rowID: 1,
      chatID: 1,
      sender: "+123",
      text: "hello",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: nil,
      attachmentsCount: 0,
      guid: "msg-guid-1"
    )
  ])

  #expect(reactionsByMessageID.isEmpty)
}

@Test
func reactionsForMessageWithNoReactionsReturnsEmpty() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now, text: "No reactions here")

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.isEmpty)
}

@Test
func reactionsForMessageRemovesReactions() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)

  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2001, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 2, 'Removed a like', 'reaction-guid-2', 'p:0/msg-guid-1', 3001, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.isEmpty)
}

@Test
func reactionsForMessageParsesCustomEmojiWithoutEnglishPrefix() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)

  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '🎉 reagiu a "Hello world"', 'reaction-guid-1', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.count == 1)
  #expect(reactions[0].reactionType == .custom("🎉"))
}

@Test
func reactionsMatchGuidWithoutPrefix() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)

  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'msg-guid-1', 2000, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.count == 1)
  #expect(reactions[0].reactionType == .love)
}

@Test
func reactionsForMessageRemovesCustomEmojiWithoutEmojiText() throws {
  let db = try ReactionTestDatabase.makeConnection()
  let now = Date()
  try ReactionTestDatabase.seedBaseMessage(db, now: now)

  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, 'Reacted 🎉 to \"Hello world\"', 'reaction-guid-1', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 2, 'Removed a reaction', 'reaction-guid-2', 'p:0/msg-guid-1', 3006, ?, 0, 'iMessage')
    """,
    ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.isEmpty)
}

@Test
func reactionsForMessageReturnsEmptyWhenColumnsMissing() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.isEmpty)
}

@Test
func reactionTypeProperties() throws {
  #expect(ReactionType.love.name == "love")
  #expect(ReactionType.love.emoji == "❤️")
  #expect(ReactionType.like.name == "like")
  #expect(ReactionType.like.emoji == "👍")
  #expect(ReactionType.dislike.name == "dislike")
  #expect(ReactionType.dislike.emoji == "👎")
  #expect(ReactionType.laugh.name == "laugh")
  #expect(ReactionType.laugh.emoji == "😂")
  #expect(ReactionType.emphasis.name == "emphasis")
  #expect(ReactionType.emphasis.emoji == "‼️")
  #expect(ReactionType.question.name == "question")
  #expect(ReactionType.question.emoji == "❓")
  #expect(ReactionType.custom("🎉").name == "custom")
  #expect(ReactionType.custom("🎉").emoji == "🎉")
}

@Test
func reactionTypeFromRawValue() throws {
  #expect(ReactionType(rawValue: 2000) == .love)
  #expect(ReactionType(rawValue: 2001) == .like)
  #expect(ReactionType(rawValue: 2002) == .dislike)
  #expect(ReactionType(rawValue: 2003) == .laugh)
  #expect(ReactionType(rawValue: 2004) == .emphasis)
  #expect(ReactionType(rawValue: 2005) == .question)
  #expect(ReactionType(rawValue: 2006, customEmoji: "🎉") == .custom("🎉"))
  #expect(ReactionType(rawValue: 2006) == nil)
  #expect(ReactionType(rawValue: 9999) == nil)
}

@Test
func reactionTypeHelpers() throws {
  #expect(ReactionType.isReactionAdd(2000) == true)
  #expect(ReactionType.isReactionAdd(2005) == true)
  #expect(ReactionType.isReactionAdd(2006) == true)
  #expect(ReactionType.isReactionAdd(1999) == false)
  #expect(ReactionType.isReactionAdd(2007) == false)

  #expect(ReactionType.isReactionRemove(3000) == true)
  #expect(ReactionType.isReactionRemove(3005) == true)
  #expect(ReactionType.isReactionRemove(3006) == true)
  #expect(ReactionType.isReactionRemove(2999) == false)
  #expect(ReactionType.isReactionRemove(3007) == false)

  #expect(ReactionType.fromRemoval(3000) == .love)
  #expect(ReactionType.fromRemoval(3001) == .like)
  #expect(ReactionType.fromRemoval(3005) == .question)
  #expect(ReactionType.fromRemoval(3006, customEmoji: "🎉") == .custom("🎉"))
}
