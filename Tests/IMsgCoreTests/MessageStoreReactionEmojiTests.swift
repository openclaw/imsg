import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum EmojiColumnDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 - MessageStore.appleEpochOffset) * 1_000_000_000)
  }

  static func make(withEmojiColumn: Bool, now: Date) throws -> Connection {
    let db = try Connection(.inMemory)
    let emojiColumn = withEmojiColumn ? ", associated_message_emoji TEXT" : ""
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, guid TEXT,
        associated_message_guid TEXT, associated_message_type INTEGER,
        date INTEGER, is_from_me INTEGER, service TEXT\(emojiColumn)
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.run("INSERT INTO chat VALUES (1, '+123', 'Test Chat', 'iMessage')")
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_type,
                          date, is_from_me, service)
      VALUES (1, 1, 'Hello world', 'msg-guid-1', 0, ?, 0, 'iMessage')
      """,
      appleEpoch(now.addingTimeInterval(-600))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    return db
  }

  static func addReaction(
    _ db: Connection, rowID: Int64, text: String, isFromMe: Int, emoji: String?, date: Date
  ) throws {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid,
                          associated_message_type, date, is_from_me, service,
                          associated_message_emoji)
      VALUES (?, 2, ?, ?, 'p:0/msg-guid-1', 2006, ?, ?, 'iMessage', ?)
      """,
      rowID, text, "reaction-guid-\(rowID)", appleEpoch(date), isFromMe, emoji
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", rowID)
  }
}

@Test(arguments: [false, true])
func customReactionPrefersAssociatedMessageEmojiColumn(bulk: Bool) throws {
  let now = Date()
  let db = try EmojiColumnDatabase.make(withEmojiColumn: true, now: now)
  // Empty text: the summary parser has nothing to read.
  try EmojiColumnDatabase.addReaction(
    db, rowID: 2, text: "", isFromMe: 0, emoji: "🎉", date: now.addingTimeInterval(-500))
  // Localized text without the English "Reacted" prefix, with a different emoji in the text.
  try EmojiColumnDatabase.addReaction(
    db, rowID: 3, text: "\"Hello world\"에 🙂 반응함", isFromMe: 1, emoji: "🔥",
    date: now.addingTimeInterval(-400))

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(store.schema.hasAssociatedMessageEmojiColumn)
  let reactions = try reactionSnapshot(store, bulk: bulk)

  #expect(reactions.map(\.reactionType) == [.custom("🎉"), .custom("🔥")])
}

@Test
func customReactionFallsBackToSummaryTextWithoutEmojiColumn() throws {
  let now = Date()
  let db = try EmojiColumnDatabase.make(withEmojiColumn: false, now: now)
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid,
                        associated_message_type, date, is_from_me, service)
    VALUES (2, 2, 'Reacted 🎉 to "Hello world"', 'reaction-guid-2', 'p:0/msg-guid-1',
            2006, ?, 0, 'iMessage')
    """,
    EmojiColumnDatabase.appleEpoch(now.addingTimeInterval(-500))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(!store.schema.hasAssociatedMessageEmojiColumn)
  #expect(try store.reactions(for: 1).map(\.reactionType) == [.custom("🎉")])
}

@Test
func emptyEmojiColumnFallsBackToSummaryText() throws {
  let now = Date()
  let db = try EmojiColumnDatabase.make(withEmojiColumn: true, now: now)
  try EmojiColumnDatabase.addReaction(
    db, rowID: 2, text: "Reacted 🎉 to \"Hello world\"", isFromMe: 0, emoji: "",
    date: now.addingTimeInterval(-500))

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.reactions(for: 1).map(\.reactionType) == [.custom("🎉")])
}

@Test
func reactionEventsUseAssociatedMessageEmojiColumn() throws {
  let now = Date()
  let db = try EmojiColumnDatabase.make(withEmojiColumn: true, now: now)
  try EmojiColumnDatabase.addReaction(
    db, rowID: 2, text: "", isFromMe: 0, emoji: "🎉", date: now.addingTimeInterval(-500))

  let store = try MessageStore(connection: db, path: ":memory:")
  let events = try store.reactionEventsAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(events.map(\.reactionType) == [.custom("🎉")])
}

private func reactionSnapshot(_ store: MessageStore, bulk: Bool) throws -> [Reaction] {
  if bulk {
    let messages = try store.messages(chatID: 1, limit: 10)
    return try store.reactions(for: messages)[1] ?? []
  }
  return try store.reactions(for: 1)
}
