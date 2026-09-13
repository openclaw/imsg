import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageStoreAttachesDecodedPollMetadata() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  options.includeBalloonBundleID = true
  options.includePayloadData = true
  options.includeMessageSummaryInfo = true
  try MessageDatabaseFixture.createSchema(db, options: options)

  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+15550001000', 'iMessage;+;chat-test', 'Poll Test', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+15550001000')")

  let definition: [String: Any] = [
    "title": "Pick one",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-b", "pollOptionText": "B"],
    ],
  ]
  let pollPayload = try PropertyListSerialization.data(
    fromPropertyList: [
      "url": try pollURL(queryName: "definition", object: definition).absoluteString
    ],
    format: .binary,
    options: 0
  )
  let pollBlob = Blob(bytes: [UInt8](pollPayload))
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (1, 1, '', 'poll-row-guid', NULL, NULL, ?, ?, NULL, ?, 0, 'iMessage')
    """,
    testPollBundleID,
    pollBlob,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (2, 1, 'hello', 'normal-row-guid', NULL, NULL, NULL, NULL, NULL, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)

  let pollMessage = try #require(messages.first { $0.guid == "poll-row-guid" })
  #expect(pollMessage.poll?.kind == .created)
  #expect(pollMessage.poll?.question == "Pick one")
  #expect(pollMessage.poll?.options?.map(\.id) == ["choice-a", "choice-b"])

  let normalMessage = try #require(messages.first { $0.guid == "normal-row-guid" })
  #expect(normalMessage.poll == nil)
}

/// Builds a title-less created poll (native polls carry no `item.title`) plus a
/// single reply row, and returns the enriched poll's question after a full
/// `messages()` read. Used to prove caption backfill picks a clean caption and
/// ignores a threaded reply.
private func backfilledPollQuestion(
  replyText: String,
  replyAssociatedType: Int?,
  replyThreadOriginator: String?,
  replyToGUID: String = "poll-row-guid"
) throws -> String? {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  options.includeBalloonBundleID = true
  options.includePayloadData = true
  options.includeMessageSummaryInfo = true
  options.includeReplyToGUID = true
  options.includeThreadOriginatorGUID = true
  try MessageDatabaseFixture.createSchema(db, options: options)

  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+15550001000', 'iMessage;+;chat-test', 'Poll Test', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+15550001000')")

  // Native created poll: empty title, so the question must come from a caption.
  let definition: [String: Any] = [
    "title": "",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-b", "pollOptionText": "B"],
    ],
  ]
  let pollPayload = try PropertyListSerialization.data(
    fromPropertyList: [
      "url": try pollURL(queryName: "definition", object: definition).absoluteString
    ],
    format: .binary,
    options: 0
  )
  let pollBlob = Blob(bytes: [UInt8](pollPayload))
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, reply_to_guid,
      thread_originator_guid, date, is_from_me, service
    )
    VALUES (1, 1, '', 'poll-row-guid', NULL, NULL, ?, ?, NULL, NULL, NULL, ?, 0, 'iMessage')
    """,
    testPollBundleID,
    pollBlob,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, reply_to_guid,
      thread_originator_guid, date, is_from_me, service
    )
    VALUES (2, 1, ?, 'reply-row-guid', NULL, ?, NULL, NULL, NULL, ?, ?, ?, 0, 'iMessage')
    """,
    replyText,
    replyAssociatedType.map { Int64($0) },
    replyToGUID,
    replyThreadOriginator,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let pollMessage = try #require(messages.first { $0.guid == "poll-row-guid" })
  #expect(pollMessage.poll?.kind == .created)
  return pollMessage.poll?.question
}

@Test
func messageStorePollBackfillsQuestionFromCleanCaption() throws {
  // A plain caption (associated_message_type 0, no thread originator) is the
  // native poll question and must backfill the empty created-poll title.
  let question = try backfilledPollQuestion(
    replyText: "What is for dinner?",
    replyAssociatedType: 0,
    replyThreadOriginator: nil
  )
  #expect(question == "What is for dinner?")
}

@Test
func messageStorePollBackfillsQuestionFromPrefixedCaptionReference() throws {
  let question = try backfilledPollQuestion(
    replyText: "What is for dinner?",
    replyAssociatedType: 0,
    replyThreadOriginator: nil,
    replyToGUID: "p:0/poll-row-guid"
  )
  #expect(question == "What is for dinner?")
}

@Test
func messageStorePollBackfillsQuestionFromNullAssociationType() throws {
  let question = try backfilledPollQuestion(
    replyText: "What is for dinner?",
    replyAssociatedType: nil,
    replyThreadOriginator: nil
  )
  #expect(question == "What is for dinner?")
}

@Test
func messageStorePollBackfillIgnoresThreadedReply() throws {
  // A threaded inline reply to the poll (type 100, thread originator set) is NOT
  // the question; with no clean caption the question must stay empty rather than
  // adopt the reply text.
  let question = try backfilledPollQuestion(
    replyText: "just a reply, not the question",
    replyAssociatedType: 100,
    replyThreadOriginator: "poll-row-guid"
  )
  #expect((question ?? "").isEmpty)
}
