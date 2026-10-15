import SQLite
import Testing

@testable import IMsgCore

@Test(arguments: ["unread", "none", "read-only"])
func unreadCountsChooseIndexedTraversal(index: String) throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db, options: MessageDatabaseFixture.SchemaOptions(includeReadState: true))
  try db.execute(
    """
    CREATE UNIQUE INDEX chat_message_join_idx ON chat_message_join(chat_id, message_id);
    INSERT INTO chat(ROWID, chat_identifier, service_name) VALUES (1, '+15551234567', 'iMessage');
    WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM ids WHERE n < 10000)
    INSERT INTO message(ROWID, text, date, is_from_me, is_read, service)
      SELECT n, 'fixture', n, 0, n != 10000, 'iMessage' FROM ids;
    INSERT INTO chat_message_join SELECT 1, ROWID FROM message;
    """)
  if index != "none" {
    let predicate = index == "read-only" ? "WHERE is_read = 1" : ""
    try db.execute("CREATE INDEX message_idx_is_read ON message(is_read, is_from_me) \(predicate)")
  }
  let store = try MessageStore(connection: db, path: ":memory:")
  var unreadSQL: String?
  db.trace { sql in
    if sql.contains("cmj.chat_id IN") { unreadSQL = sql }
  }
  let chats = try store.listChats(limit: 1)
  db.trace(nil)
  #expect(chats.first?.unreadCount == 1)

  let sql = try #require(unreadSQL)
  let plan = try db.prepare("EXPLAIN QUERY PLAN \(sql)").map { row in
    row[3] as? String ?? ""
  }
  let chatSearch = try #require(plan.firstIndex { $0.contains("SEARCH cmj USING") })
  if index == "unread" {
    let messageSearch = try #require(
      plan.firstIndex { $0.contains("SEARCH m USING INDEX message_idx_is_read") })
    #expect(messageSearch < chatSearch)
  } else {
    let messageSearch = try #require(
      plan.firstIndex { $0.contains("SEARCH m USING INTEGER PRIMARY KEY") })
    #expect(chatSearch < messageSearch)
  }
}
