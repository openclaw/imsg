import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(
  arguments: [false, true],
  [
    "correct", "wrong-account", "wrong-participant", "group", "wrong-service", "ambiguous",
    "not-recovered",
  ])
func recoveredDirectChatReceiptStaysBoundToParticipantAndAccount(attachment: Bool, kind: String)
  throws
{
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let now = Date()
  let path = "/synthetic/imsg/unique-attempt/photo.png"
  try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("DELETE FROM chat_handle_join WHERE chat_id = 1 AND handle_id = 2")
    try db.run(
      "INSERT INTO chat(ROWID, chat_identifier, guid, service_name, account_id) VALUES (2, '+123', ?, 'iMessage', ?)",
      kind == "group" ? "any;+;chat123" : "any;-;+123",
      kind == "wrong-account" ? "other-account" : "iMessage;+;me@icloud.com")
    try db.run(
      "INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (2, ?)",
      kind == "wrong-participant" ? 2 : 1)
    if kind == "group" {
      try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (2, 2)")
    }
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (99, 1, ?, 'receipt-99', ?, 1, ?)",
      attachment ? "" : "nonce", CommandTestDatabase.appleEpoch(now),
      kind == "wrong-service" ? "SMS" : "iMessage")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 99)")
    try db.run("INSERT INTO attachment(ROWID, filename) VALUES (99, ?)", path)
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (99, 99)")
    if kind == "ambiguous" {
      try db.run(
        "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (100, 1, ?, 'receipt-100', ?, 1, 'iMessage')",
        attachment ? "" : "nonce", CommandTestDatabase.appleEpoch(now))
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 100)")
      try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (100, 99)")
    }
  }
  let chat = try #require(try store.chatInfo(chatID: 1))
  let target = try #require(
    DirectParticipantTarget(chat: chat, participants: try store.participants(chatID: 1)))
  var options = MessageSendOptions(
    recipient: "", text: attachment ? "" : "nonce", attachmentPath: attachment ? path : "",
    service: .imessage, chatGUID: chat.guid, directParticipantTarget: target)
  options.usedDirectParticipantRecovery = kind != "not-recovered"
  let receipt = try SentMessageVerifier.resolveSentMessageCandidate(
    store: store, options: options, chatID: 1, since: now.addingTimeInterval(-2))
  #expect(receipt?.rowID == (kind == "correct" ? 99 : nil))
  if kind == "correct" { #expect(receipt?.chatID == 2) }
}
