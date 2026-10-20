import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesUseDestinationCallerIDWhenSenderMissing() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      destination_caller_id TEXT,
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

  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, destination_caller_id, date, is_from_me, service)
    VALUES (1, NULL, 'hello', 'me@icloud.com', ?, 1, 'iMessage')
    """,
    Int64(Date().timeIntervalSince1970 - MessageStore.appleEpochOffset) * 1_000_000_000
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 5)
  #expect(messages.first?.sender == "me@icloud.com")
  #expect(messages.first?.destinationCallerID == "me@icloud.com")
}

private let localAccount = "+15550000001"
private let peer = "+15550000002"

// Since macOS 13, outgoing 1:1 rows carry the recipient's handle_id instead of 0.
private func makeDirectChatStore(withUnresolvedIncomingReaction: Bool = false) throws
  -> MessageStore
{
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeDestinationCallerID = true
  options.includeReactionColumns = true
  try MessageDatabaseFixture.createSchema(db, options: options)
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, ?, ?, '', 'iMessage')",
    peer, "iMessage;-;\(peer)")
  try db.run("INSERT INTO handle(ROWID, id) VALUES (2, ?)", peer)
  let rows: [(rowID: Int64, isFromMe: Int, destination: String?, associatedType: Int?)] = [
    (1, 0, localAccount, nil),
    (2, 1, localAccount, nil),
    (3, 1, nil, nil),
    (4, 0, localAccount, 2000),
    (5, 1, localAccount, 2001),
  ]
  for row in rows {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid,
        associated_message_type, destination_caller_id, date, is_from_me, service)
      VALUES (?, 2, 'text', ?, ?, ?, ?, ?, ?, 'iMessage')
      """,
      row.rowID, "guid-\(row.rowID)", row.associatedType == nil ? nil : "p:0/guid-1",
      row.associatedType, row.destination, row.rowID * 1_000_000_000, row.isFromMe)
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", row.rowID)
  }
  if withUnresolvedIncomingReaction {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid,
        associated_message_type, destination_caller_id, date, is_from_me, service)
      VALUES (6, 0, 'text', 'guid-6', 'p:0/guid-1', 2001, ?, 6000000000, 0, 'iMessage')
      """, localAccount)
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
  }
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func outgoingDirectMessagesReportLocalAccountAsSender() throws {
  let store = try makeDirectChatStore()
  let senders = Dictionary(
    uniqueKeysWithValues: try store.messages(chatID: 1, limit: 10).map { ($0.rowID, $0.sender) })
  #expect(senders == [1: peer, 2: localAccount, 3: peer])
}

@Test
func outgoingReactionEventsReportLocalAccountAsSender() throws {
  let store = try makeDirectChatStore()
  let senders = try store.reactionEventsAfter(afterRowID: 0, chatID: nil, limit: 10)
    .map { [$0.rowID: $0.sender] }
  #expect(senders == [[4: peer], [5: localAccount]])
}

@Test
func outgoingReactionSummariesReportLocalAccountAsSender() throws {
  let store = try makeDirectChatStore()
  let messages = try store.messages(chatID: 1, limit: 10)
  let batched = try store.reactions(for: messages)[1] ?? []
  for reactions in [try store.reactions(for: 1), batched] {
    #expect(reactions.map { [$0.rowID: $0.sender] } == [[4: peer], [5: localAccount]])
  }
}

// A received reaction without a handle must not borrow the local account as its sender.
@Test
func incomingReactionSummariesKeepUnresolvedSender() throws {
  let store = try makeDirectChatStore(withUnresolvedIncomingReaction: true)
  let messages = try store.messages(chatID: 1, limit: 10)
  let batched = try store.reactions(for: messages)[1] ?? []
  for reactions in [try store.reactions(for: 1), batched] {
    #expect(reactions.first { $0.rowID == 6 }?.sender == "")
  }
}

@Test(arguments: [[localAccount], [peer], [localAccount, peer]])
func participantFilterMatchesResolvedSender(participants: [String]) throws {
  let store = try makeDirectChatStore()
  let filter = MessageFilter(participants: participants)
  let queried = try store.messages(chatID: 1, limit: 10, filter: filter).map(\.rowID)
  let decoded = try store.messages(chatID: 1, limit: 10).filter(filter.allows).map(\.rowID)
  #expect(queried == decoded)
  #expect(!queried.isEmpty)
}
