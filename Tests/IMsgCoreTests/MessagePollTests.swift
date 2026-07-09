import Foundation
import SQLite
import Testing

@testable import IMsgCore

// swiftlint:disable file_length

private let testPollBundleID =
  "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls"

@Test
func decodesPollCreationPayloadFromArchivedURL() throws {
  let definition: [String: Any] = [
    "title": "Dinner plan?",
    "creatorHandle": "+15550001000",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "Pizza"],
      ["optionIdentifier": "choice-b", "pollOptionText": "Sushi"],
    ],
  ]
  let url = try pollURL(queryName: "definition", object: definition)
  let payload = try NSKeyedArchiver.archivedData(
    withRootObject: ["url": url],
    requiringSecureCoding: false
  )

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: nil,
    associatedMessageGUID: "",
    messageGUID: "poll-message-guid",
    sender: "+15550001000"
  )

  #expect(poll?.kind == .created)
  #expect(poll?.event == "imessage.poll.created")
  #expect(poll?.pollGUID == "poll-message-guid")
  #expect(poll?.question == "Dinner plan?")
  #expect(poll?.creator == "+15550001000")
  #expect(
    poll?.options == [
      MessagePollOption(id: "choice-a", text: "Pizza"),
      MessagePollOption(id: "choice-b", text: "Sushi"),
    ])
  #expect(poll?.metadata?.queryKeys == ["definition", "source"])
}

@Test
func decodesPollCreationPayloadFromAppleDataURLEnvelope() throws {
  let definition: [String: Any] = [
    "item": [
      "title": "Dinner plan?",
      "creatorHandle": "+15550001000",
      "orderedPollOptions": [
        [
          "creatorHandle": "+15550001000",
          "canBeEdited": false,
          "attributedText": "Pizza",
          "text": "Pizza",
          "optionIdentifier": "choice-a",
        ],
        [
          "creatorHandle": "+15550001000",
          "canBeEdited": false,
          "attributedText": "Sushi",
          "text": "Sushi",
          "optionIdentifier": "choice-b",
        ],
      ],
    ],
    "version": 1,
  ]
  let payload = try applePollEnvelopePayload(jsonObject: definition, query: "src=p&c=2")

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: nil,
    associatedMessageGUID: "",
    messageGUID: "poll-message-guid",
    sender: "+15550001000"
  )

  #expect(poll?.kind == .created)
  #expect(poll?.event == "imessage.poll.created")
  #expect(poll?.question == "Dinner plan?")
  #expect(poll?.creator == "+15550001000")
  #expect(
    poll?.options == [
      MessagePollOption(id: "choice-a", text: "Pizza"),
      MessagePollOption(id: "choice-b", text: "Sushi"),
    ])
  #expect(poll?.metadata?.queryKeys == ["c", "src"])
}

@Test
func decodesPollCreationUsesSenderAsCreatorFallback() throws {
  let definition: [String: Any] = [
    "title": "Dinner plan?",
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "Pizza"],
      ["optionIdentifier": "choice-b", "pollOptionText": "Sushi"],
    ],
  ]
  let payload = try applePollEnvelopePayload(jsonObject: definition)

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: nil,
    associatedMessageGUID: "",
    messageGUID: "poll-message-guid",
    sender: "+15550001000"
  )

  #expect(poll?.kind == .created)
  #expect(poll?.creator == "+15550001000")
  #expect(poll?.participants == ["+15550001000"])
}

@Test
func decodesPollOptionUpdateWithOriginalPollReference() throws {
  let update: [String: Any] = [
    "orderedPollOptions": [
      ["optionIdentifier": "choice-a", "pollOptionText": "Pizza"],
      ["optionIdentifier": "choice-b", "pollOptionText": "Sushi"],
      ["optionIdentifier": "choice-c", "pollOptionText": "Tacos"],
    ]
  ]
  let payload = try applePollEnvelopePayload(jsonObject: update)

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 2,
    associatedMessageGUID: "p/original-poll-guid",
    messageGUID: "updated-poll-guid",
    sender: "+15550002000"
  )

  #expect(poll?.kind == .created)
  #expect(poll?.event == "imessage.poll.created")
  #expect(poll?.pollGUID == "updated-poll-guid")
  #expect(poll?.originalGUID == "original-poll-guid")
  #expect(poll?.metadata?.associatedMessageType == 2)
  #expect(
    poll?.options == [
      MessagePollOption(id: "choice-a", text: "Pizza"),
      MessagePollOption(id: "choice-b", text: "Sushi"),
      MessagePollOption(id: "choice-c", text: "Tacos"),
    ])
}

@Test
func decodesPollVotePayloadFromBinaryPlistURL() throws {
  let response: [String: Any] = [
    "votes": [
      [
        "voteOptionIdentifier": "choice-b",
        "participantHandle": "+15550002000",
        "eventType": "selected",
        "serverVoteTime": 123_456,
      ]
    ]
  ]
  let url = try pollURL(queryName: "response", object: response)
  let payload = try PropertyListSerialization.data(
    fromPropertyList: ["messageURL": url.absoluteString],
    format: .binary,
    options: 0
  )

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 4000,
    associatedMessageGUID: "original-poll-guid",
    messageGUID: "vote-row-guid",
    sender: "+15550002000"
  )

  #expect(poll?.kind == .vote)
  #expect(poll?.event == "imessage.poll.voted")
  #expect(poll?.pollGUID == "original-poll-guid")
  #expect(poll?.originalGUID == "original-poll-guid")
  #expect(
    poll?.vote
      == MessagePollVote(
        optionID: "choice-b",
        participant: "+15550002000",
        eventType: "selected",
        serverTime: "123456"
      ))
  #expect(poll?.participants == ["+15550002000"])
}

@Test
func decodesPollVoteDoesNotInferCreatorFromSender() throws {
  let response: [String: Any] = [
    "votes": [
      [
        "voteOptionIdentifier": "choice-b",
        "eventType": "selected",
      ]
    ]
  ]
  let payload = try applePollEnvelopePayload(jsonObject: response)

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 4000,
    associatedMessageGUID: "original-poll-guid",
    messageGUID: "vote-row-guid",
    sender: "+15550002000"
  )

  #expect(poll?.kind == .vote)
  #expect(poll?.creator == nil)
  #expect(poll?.vote?.participant == "+15550002000")
  #expect(poll?.participants == ["+15550002000"])
}

@Test
func decodesPollVotePayloadFromAppleDataURLEnvelope() throws {
  let response: [String: Any] = [
    "item": [
      "votes": [
        [
          "voteOptionIdentifier": "choice-b",
          "participantHandle": "+15550002000",
        ]
      ]
    ],
    "version": 1,
  ]
  let payload = try applePollEnvelopePayload(jsonObject: response)

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 4000,
    associatedMessageGUID: "original-poll-guid",
    messageGUID: "vote-row-guid",
    sender: "+15550002000"
  )

  #expect(poll?.kind == .vote)
  #expect(poll?.event == "imessage.poll.voted")
  #expect(poll?.pollGUID == "original-poll-guid")
  #expect(
    poll?.vote
      == MessagePollVote(
        optionID: "choice-b",
        participant: "+15550002000",
        eventType: "selected"
      ))
}

@Test
func decodesPollUnvotePayloadFromEmptyVotesArray() throws {
  let response: [String: Any] = [
    "item": [
      "votes": []
    ],
    "version": 1,
  ]
  let payload = try applePollEnvelopePayload(jsonObject: response)

  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 4000,
    associatedMessageGUID: "original-poll-guid",
    messageGUID: "vote-row-guid",
    sender: "+15550002000"
  )

  #expect(poll?.kind == .vote)
  #expect(poll?.event == "imessage.poll.voted")
  #expect(poll?.pollGUID == "original-poll-guid")
  #expect(poll?.vote == nil)
  #expect(poll?.votes?.isEmpty ?? true)
}

@Test
func malformedPollPayloadEmitsUnknownWithoutRawPayload() throws {
  let poll = MessagePollDecoder.decode(
    balloonBundleID: testPollBundleID,
    payloadData: Data([0x00, 0x01, 0x02]),
    messageSummaryInfo: Data(),
    associatedMessageType: nil,
    associatedMessageGUID: "",
    messageGUID: "unknown-poll-guid",
    sender: "+15550001000"
  )

  #expect(poll?.kind == .unknown)
  #expect(poll?.event == "imessage.poll.unknown")
  #expect(poll?.metadata?.payloadBytes == 3)
  let encoded = try JSONEncoder().encode(poll)
  let json = String(decoding: encoded, as: UTF8.self)
  #expect(!json.contains("AAEC"))
}

@Test
func nonPollMessagesAreUnaffected() throws {
  let payload = try PropertyListSerialization.data(
    fromPropertyList: ["title": "Not a poll"],
    format: .binary,
    options: 0
  )

  let poll = MessagePollDecoder.decode(
    balloonBundleID: "com.apple.messages.URLBalloonProvider",
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: nil,
    associatedMessageGUID: "",
    messageGUID: "normal-message-guid",
    sender: "+15550001000"
  )

  #expect(poll == nil)
}

@Test
func nonPollAssociatedTypeRowsAreUnaffectedWithoutPollEvidence() throws {
  let payload = try PropertyListSerialization.data(
    fromPropertyList: ["title": "Not a poll"],
    format: .binary,
    options: 0
  )

  let poll = MessagePollDecoder.decode(
    balloonBundleID: "",
    payloadData: payload,
    messageSummaryInfo: Data(),
    associatedMessageType: 4000,
    associatedMessageGUID: "associated-message-guid",
    messageGUID: "normal-message-guid",
    sender: "+15550001000"
  )

  #expect(poll == nil)
}

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

@Test
func messageStoreResolvesVoteOptionTextFromPollUpdateRows() throws {
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
    VALUES (1, 1, '', 'updated-poll-guid', 'p/original-poll-guid', 2, ?, ?, NULL, ?, 0, 'iMessage')
    """,
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
    VALUES (2, 1, '', 'vote-row-guid', 'p/updated-poll-guid', 4000, NULL, ?, NULL, ?, 0, 'iMessage')
    """,
    voteBlob,
    TestDatabase.appleEpoch(now.addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

  let store = try MessageStore(connection: db, path: ":memory:")
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

@Test
func messageRowSelectionGatesPollPayloadBlobs() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  options.includeBalloonBundleID = true
  options.includePayloadData = true
  options.includeMessageSummaryInfo = true
  try MessageDatabaseFixture.createSchema(db, options: options)

  let store = try MessageStore(connection: db, path: ":memory:")
  let query = ChatMessagesQuery(
    store: store,
    chatID: ChatID(rawValue: 1),
    limit: 10,
    filter: nil
  )

  #expect(query.selection.selectList.contains("CASE WHEN"))
  #expect(query.selection.selectList.contains("m.associated_message_type = 4000"))
  #expect(query.selection.selectList.contains("m.payload_data ELSE NULL"))
  #expect(query.selection.selectList.contains("m.message_summary_info ELSE NULL"))
  #expect(!query.selection.selectList.contains("m.payload_data AS payload_data"))
  #expect(!query.selection.selectList.contains("m.message_summary_info AS message_summary_info"))
}

private func pollURL(queryName: String, object: [String: Any]) throws -> URL {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let encoded = data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  var components = URLComponents()
  components.scheme = "messages-polls"
  components.host = "poll"
  components.queryItems = [
    URLQueryItem(name: "source", value: "sendMenu"),
    URLQueryItem(name: queryName, value: encoded),
  ]
  return try #require(components.url)
}

private func applePollEnvelopePayload(jsonObject: [String: Any], query: String = "") throws
  -> Data
{
  let json = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
  let encoded = json.base64EncodedString()
  let suffix = query.isEmpty ? "" : "?\(query)"
  let url = try #require(URL(string: "data:,\(encoded)\(suffix)"))
  return try NSKeyedArchiver.archivedData(
    withRootObject: [
      "URL": url,
      "sessionIdentifier": UUID(),
      "an": "Polls",
    ],
    requiringSecureCoding: false
  )
}
