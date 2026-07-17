import Foundation
import SQLite
import Testing

@testable import IMsgCore

private func makeStoreWithoutChatRouting() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeChatRouting: false)
  )
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;+;chat123', 'Legacy Chat', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (1, NULL, 'hello', ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_700_000_000))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func schemaDetectsOptionalMessageColumns() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeAttributedBody: true,
      includeReactionColumns: true,
      includeThreadOriginatorGUID: true,
      includeThreadOriginatorPart: true,
      includeDestinationCallerID: true,
      includeAudioMessage: true,
      includeBalloonBundleID: true,
      includeAttachmentUserInfo: true,
      includeChatMessageDate: true,
      includeChatRouting: true
    )
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(store.schema.hasAttributedBody)
  #expect(store.schema.hasReactionColumns)
  #expect(store.schema.hasGUIDColumn)
  #expect(store.schema.hasThreadOriginatorGUIDColumn)
  #expect(store.schema.hasThreadOriginatorPartColumn)
  #expect(store.schema.hasDestinationCallerID)
  #expect(store.schema.hasAudioMessageColumn)
  #expect(store.schema.hasBalloonBundleIDColumn)
  #expect(store.schema.hasAttachmentUserInfo)
  #expect(store.schema.hasChatMessageJoinMessageDateColumn)
  #expect(store.schema.hasChatAccountIDColumn)
  #expect(store.schema.hasChatAccountLoginColumn)
  #expect(store.schema.hasChatLastAddressedHandleColumn)
}

@Test
func schemaOverridesKeepLegacyTestFixturesExplicit() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(
      includeAttributedBody: true,
      includeReactionColumns: true
    )
  )

  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  #expect(!store.schema.hasAttributedBody)
  #expect(!store.schema.hasReactionColumns)
}

@Test
func listChatsHandlesMissingRoutingColumns() throws {
  let store = try makeStoreWithoutChatRouting()

  let chats = try store.listChats(limit: 1)

  #expect(chats.count == 1)
  #expect(chats.first?.name == "Legacy Chat")
  #expect(chats.first?.accountID == nil)
  #expect(chats.first?.accountLogin == nil)
  #expect(chats.first?.lastAddressedHandle == nil)
}

@Test
func chatInfoHandlesMissingRoutingColumns() throws {
  let store = try makeStoreWithoutChatRouting()

  let info = try #require(try store.chatInfo(chatID: 1))

  #expect(info.name == "Legacy Chat")
  #expect(info.accountID == nil)
  #expect(info.accountLogin == nil)
  #expect(info.lastAddressedHandle == nil)
}
