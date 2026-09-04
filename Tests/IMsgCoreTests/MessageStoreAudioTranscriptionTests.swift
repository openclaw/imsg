import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test(arguments: [String?.none, "placeholder"], [false, true])
func audioMessageQueriesUseAvailableTranscript(text: String?, leadingEmptyAttachment: Bool) throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db, options: .init(includeAudioMessage: true, includeAttachmentUserInfo: true))
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_audio_message)
    VALUES (1, 1, ?, 700000000000000000, 0, 'iMessage', 1)
    """, text)
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  if leadingEmptyAttachment {
    try db.run("INSERT INTO attachment(ROWID) VALUES (1)")
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")
  }
  let transcript = "CAFÉ voice transcript"
  let info = try PropertyListSerialization.data(
    fromPropertyList: ["audio-transcription": transcript], format: .binary, options: 0)
  try db.run("INSERT INTO attachment(ROWID, user_info) VALUES (2, ?)", Blob(bytes: Array(info)))
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 2)")
  let store = try MessageStore(connection: db, path: ":memory:")

  #expect(try store.messages(chatID: 1, limit: 1).first?.text == transcript)
  #expect(try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 1).first?.text == transcript)
  #expect(
    try store.searchMessages(query: "café", match: "contains", limit: 1).first?.text == transcript)
  #expect(
    try store.searchMessages(query: "café voice transcript", match: "exact", limit: 1).first?.text
      == transcript)
  #expect(try store.searchMessages(query: "placeholder", match: "exact", limit: 1).isEmpty)
}
