import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func listChatsReturnsChat() throws {
  let store = try TestDatabase.makeStore()
  let chats = try store.listChats(limit: 5)
  #expect(chats.count == 1)
  #expect(chats.first?.identifier == "+123")
  #expect(chats.first?.accountID == "iMessage;+;me@icloud.com")
  #expect(chats.first?.accountLogin == "me@icloud.com")
  #expect(chats.first?.lastAddressedHandle == "+15551234567")
}

@Test
func listChatsUsesChatMessageJoinDateWithoutMessageJoinWhenAvailable() throws {
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
  try db.execute(
    """
    CREATE TABLE chat_message_join (
      chat_id INTEGER,
      message_id INTEGER,
      message_date INTEGER
    );
    """
  )
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'Old Chat', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'New Chat', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO chat_message_join(chat_id, message_id, message_date)
    VALUES
      (1, 100, ?),
      (2, 200, ?)
    """,
    TestDatabase.appleEpoch(Date(timeIntervalSince1970: 100)),
    TestDatabase.appleEpoch(Date(timeIntervalSince1970: 200))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 1)
  #expect(chats.count == 1)
  #expect(chats.first?.identifier == "+222")
  #expect(chats.first?.accountID == nil)
  #expect(chats.first?.accountLogin == nil)
  #expect(chats.first?.lastAddressedHandle == nil)
}

@Test(arguments: [false, true])
func chatNamesFallBackForEmptyAndNullDisplayNames(hasJoinDate: Bool) throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, guid TEXT,
      display_name TEXT, service_name TEXT
    );
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    INSERT INTO chat VALUES
      (1, 'empty@example.invalid', 'iMessage;-;empty@example.invalid', '', 'iMessage'),
      (2, 'null@example.invalid', 'iMessage;-;null@example.invalid', NULL, 'iMessage'),
      (3, 'chat123', 'iMessage;+;chat123', 'Study Group', 'iMessage');
    INSERT INTO message VALUES (1, 100), (2, 200), (3, 300);
    INSERT INTO chat_message_join VALUES (1, 1), (2, 2), (3, 3);
    """
  )
  if hasJoinDate {
    try db.execute(
      """
      ALTER TABLE chat_message_join ADD COLUMN message_date INTEGER;
      UPDATE chat_message_join SET message_date = message_id * 100;
      """
    )
  }

  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 3)
  #expect(chats.map(\.name) == ["Study Group", "null@example.invalid", "empty@example.invalid"])
  for chat in chats {
    let info = try #require(try store.chatInfo(chatID: chat.id))
    #expect(info.name == chat.name)
  }
}
