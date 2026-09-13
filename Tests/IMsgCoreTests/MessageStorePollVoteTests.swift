import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageStoreDecodesPollVoteRowsWithPayloadGate() throws {
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
  try db.run(
    "INSERT INTO handle(ROWID, id) VALUES (1, '+15550002000'), (2, '+15550001000')")

  let definition: [String: Any] = [
    "title": "Pick one",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-b", "pollOptionText": "B"],
    ],
  ]
  let pollPayload = try applePollEnvelopePayload(jsonObject: definition)
  let pollBlob = Blob(bytes: [UInt8](pollPayload))

  let response: [String: Any] = [
    "votes": [
      ["voteOptionIdentifier": "choice-a"]
    ]
  ]
  let votePayload = try applePollEnvelopePayload(jsonObject: response)
  let voteBlob = Blob(bytes: [UInt8](votePayload))
  let unvotePayload = try applePollEnvelopePayload(jsonObject: ["votes": []])
  let unvoteBlob = Blob(bytes: [UInt8](unvotePayload))
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (1, 2, '', 'original-poll-guid', NULL, NULL, ?, ?, NULL, ?, 1, 'iMessage')
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
    VALUES (2, 1, '', 'vote-row-guid', 'p/original-poll-guid', 4000, NULL, ?, NULL, ?, 0, 'iMessage')
    """,
    voteBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (3, 1, '', 'unvote-row-guid', 'p/original-poll-guid', 4000, NULL, ?, NULL, ?, 0, 'iMessage')
    """,
    unvoteBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(2))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let voteMessage = try #require(messages.first { $0.guid == "vote-row-guid" })
  let unvoteMessage = try #require(messages.first { $0.guid == "unvote-row-guid" })
  let streamedMessages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let streamedVote = try #require(streamedMessages.first { $0.guid == "vote-row-guid" })
  let streamedUnvote = try #require(streamedMessages.first { $0.guid == "unvote-row-guid" })

  #expect(voteMessage.poll?.kind == .vote)
  #expect(voteMessage.poll?.originalGUID == "original-poll-guid")
  #expect(voteMessage.poll?.creator == nil)
  #expect(voteMessage.poll?.vote?.participant == "+15550002000")
  #expect(voteMessage.poll?.vote?.optionID == "choice-a")
  #expect(voteMessage.poll?.vote?.optionText == "A")
  #expect(unvoteMessage.poll?.kind == .vote)
  #expect(unvoteMessage.poll?.originalGUID == "original-poll-guid")
  #expect(unvoteMessage.poll?.vote == nil)
  #expect(unvoteMessage.poll?.votes?.isEmpty ?? true)
  #expect(streamedVote.poll?.kind == .vote)
  #expect(streamedVote.poll?.vote?.optionText == "A")
  #expect(streamedUnvote.poll?.kind == .vote)
  #expect(streamedUnvote.poll?.vote == nil)
  #expect(streamedUnvote.poll?.votes?.isEmpty ?? true)
}

@Test(arguments: ["original-poll-guid", "p/original-poll-guid", "p:0/original-poll-guid"])
func messageStoreResolvesVoteOptionTextFromPollUpdateRows(updateReference: String) throws {
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
  try db.run(
    "INSERT INTO handle(ROWID, id) VALUES (1, '+15550002000'), (2, '+15550001000')")

  let update: [String: Any] = [
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-custom", "pollOptionText": "Custom choice"],
    ]
  ]
  let updateBlob = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: update)))
  let vote: [String: Any] = [
    "votes": [
      ["voteOptionIdentifier": "choice-custom"]
    ]
  ]
  let voteBlob = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: vote)))
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (1, 1, '', 'updated-poll-guid', ?, 2, ?, ?, NULL, ?, 0, 'iMessage')
    """,
    updateReference,
    testPollBundleID,
    updateBlob,
    TestDatabase.appleEpoch(now)
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (2, 1, '', 'vote-row-guid', 'p/updated-poll-guid', 4000, NULL, ?, NULL, ?, 1, 'iMessage')
    """,
    voteBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.pollSelectedOptionIDs(guid: "original-poll-guid") == ["choice-custom"])
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let updateMessage = try #require(messages.first { $0.guid == "updated-poll-guid" })
  let voteMessage = try #require(messages.first { $0.guid == "vote-row-guid" })

  #expect(updateMessage.poll?.kind == .created)
  #expect(updateMessage.poll?.originalGUID == "original-poll-guid")
  #expect(updateMessage.poll?.options?.map(\.text) == ["A", "Custom choice"])
  #expect(voteMessage.poll?.kind == .vote)
  #expect(voteMessage.poll?.pollGUID == "original-poll-guid")
  #expect(voteMessage.poll?.originalGUID == "original-poll-guid")
  #expect(voteMessage.poll?.vote?.optionID == "choice-custom")
  #expect(voteMessage.poll?.vote?.optionText == "Custom choice")
}

@Test
func messageStoreResolvesOriginalPollVoteOptionTextFromSlashUpdateRows() throws {
  try assertOriginalPollVoteOptionTextResolvesFromUpdateRow(
    updateAssociatedGUID: "p/original-poll-guid")
}

@Test
func messageStoreResolvesOriginalPollVoteOptionTextFromPartPrefixedUpdateRows() throws {
  try assertOriginalPollVoteOptionTextResolvesFromUpdateRow(
    updateAssociatedGUID: "p:0/original-poll-guid")
}

private func assertOriginalPollVoteOptionTextResolvesFromUpdateRow(
  updateAssociatedGUID: String
) throws {
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
  try db.run(
    "INSERT INTO handle(ROWID, id) VALUES (1, '+15550002000'), (2, '+15550001000')")

  let poll: [String: Any] = [
    "question": "Dinner?",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-b", "pollOptionText": "B"],
    ],
  ]
  let pollBlob = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: poll)))
  let update: [String: Any] = [
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "A"],
      ["optionIdentifier": "choice-b", "pollOptionText": "B"],
      ["optionIdentifier": "choice-custom", "pollOptionText": "Custom choice"],
    ]
  ]
  let updateBlob = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: update)))
  let vote: [String: Any] = [
    "votes": [
      ["voteOptionIdentifier": "choice-custom"]
    ]
  ]
  let voteBlob = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: vote)))
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (1, 2, '', 'original-poll-guid', NULL, NULL, ?, ?, NULL, ?, 1, 'iMessage')
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
    VALUES (2, 1, '', 'updated-poll-guid', ?, 2, ?, ?, NULL, ?, 0, 'iMessage')
    """,
    updateAssociatedGUID,
    testPollBundleID,
    updateBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      balloon_bundle_id, payload_data, message_summary_info, date, is_from_me, service
    )
    VALUES (3, 1, '', 'vote-row-guid', 'p/original-poll-guid', 4000, NULL, ?, NULL, ?, 0, 'iMessage')
    """,
    voteBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(2))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(
    try store.pollOptions(guid: "original-poll-guid").map(\.text) == [
      "A", "B", "Custom choice",
    ])

  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let voteMessage = try #require(messages.first { $0.guid == "vote-row-guid" })

  #expect(voteMessage.poll?.kind == .vote)
  #expect(voteMessage.poll?.originalGUID == "original-poll-guid")
  #expect(voteMessage.poll?.vote?.optionID == "choice-custom")
  #expect(voteMessage.poll?.vote?.optionText == "Custom choice")
}
