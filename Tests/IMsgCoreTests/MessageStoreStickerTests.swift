import SQLite
import Testing

@testable import IMsgCore

@Test
func stickerTargetMembershipRequiresTheSelectedChat() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: MessageDatabaseFixture.SchemaOptions(includeReactionColumns: true)
  )
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES
      (1, '+111', 'iMessage;-;+111', 'One', 'iMessage'),
      (2, '+222', 'iMessage;-;+222', 'Two', 'iMessage'),
      (3, 'stored-group-id', 'any;-;chat123', 'Group', 'iMessage')
    """
  )
  try db.run(
    """
    INSERT INTO message(ROWID, text, guid, date, is_from_me, service)
    VALUES
      (1, 'anchor', 'anchor-guid', 1, 1, 'iMessage'),
      (2, 'group anchor', 'group-anchor-guid', 2, 1, 'iMessage')
    """
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (3, 2)")
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(
    try store.messageBelongsToChat(
      messageGUID: "anchor-guid",
      chatGUID: "iMessage;-;+111"
    ))
  #expect(
    try !store.messageBelongsToChat(
      messageGUID: "anchor-guid",
      chatGUID: "iMessage;-;+222"
    ))
  #expect(
    try store.messageBelongsToChat(
      messageGUID: "group-anchor-guid",
      chatGUID: "iMessage;+;chat123"
    ))
}
