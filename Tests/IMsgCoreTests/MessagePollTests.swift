import Foundation
import SQLite
import Testing

@testable import IMsgCore

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
