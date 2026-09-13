import Foundation

public enum MessagePollKind: String, Codable, Sendable, Equatable {
  case created
  case vote
  case unknown
}

public struct MessagePollOption: Codable, Sendable, Equatable {
  public let id: String
  public let text: String

  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

public struct MessagePollVote: Codable, Sendable, Equatable {
  public let optionID: String
  public let optionText: String?
  public let participant: String?
  public let eventType: String?
  public let serverTime: String?

  public init(
    optionID: String,
    optionText: String? = nil,
    participant: String? = nil,
    eventType: String? = nil,
    serverTime: String? = nil
  ) {
    self.optionID = optionID
    self.optionText = optionText
    self.participant = participant
    self.eventType = eventType
    self.serverTime = serverTime
  }

  enum CodingKeys: String, CodingKey {
    case optionID = "option_id"
    case optionText = "option_text"
    case participant
    case eventType = "event_type"
    case serverTime = "server_time"
  }
}

public struct MessagePollMetadata: Codable, Sendable, Equatable {
  public let bundleID: String?
  public let associatedMessageType: Int?
  public let payloadBytes: Int?
  public let summaryBytes: Int?
  public let urlScheme: String?
  public let urlHost: String?
  public let queryKeys: [String]?

  public init(
    bundleID: String? = nil,
    associatedMessageType: Int? = nil,
    payloadBytes: Int? = nil,
    summaryBytes: Int? = nil,
    urlScheme: String? = nil,
    urlHost: String? = nil,
    queryKeys: [String]? = nil
  ) {
    self.bundleID = bundleID
    self.associatedMessageType = associatedMessageType
    self.payloadBytes = payloadBytes
    self.summaryBytes = summaryBytes
    self.urlScheme = urlScheme
    self.urlHost = urlHost
    self.queryKeys = queryKeys
  }

  enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case associatedMessageType = "associated_message_type"
    case payloadBytes = "payload_bytes"
    case summaryBytes = "summary_bytes"
    case urlScheme = "url_scheme"
    case urlHost = "url_host"
    case queryKeys = "query_keys"
  }
}

public struct MessagePollEvent: Codable, Sendable, Equatable {
  public let kind: MessagePollKind
  public let event: String
  public let pollGUID: String?
  public let question: String?
  public let options: [MessagePollOption]?
  public let vote: MessagePollVote?
  public let votes: [MessagePollVote]?
  public let originalGUID: String?
  public let creator: String?
  public let participants: [String]?
  public let metadata: MessagePollMetadata?

  public init(
    kind: MessagePollKind,
    pollGUID: String? = nil,
    question: String? = nil,
    options: [MessagePollOption]? = nil,
    vote: MessagePollVote? = nil,
    votes: [MessagePollVote]? = nil,
    originalGUID: String? = nil,
    creator: String? = nil,
    participants: [String]? = nil,
    metadata: MessagePollMetadata? = nil
  ) {
    self.kind = kind
    switch kind {
    case .created:
      self.event = "imessage.poll.created"
    case .vote:
      self.event = "imessage.poll.voted"
    case .unknown:
      self.event = "imessage.poll.unknown"
    }
    self.pollGUID = pollGUID
    self.question = question
    self.options = options?.isEmpty == false ? options : nil
    self.vote = vote
    self.votes = votes?.isEmpty == false ? votes : nil
    self.originalGUID = originalGUID
    self.creator = creator
    self.participants = participants?.isEmpty == false ? participants : nil
    self.metadata = metadata
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case event
    case pollGUID = "poll_guid"
    case question
    case options
    case vote
    case votes
    case originalGUID = "original_guid"
    case creator
    case participants
    case metadata
  }
}

extension MessagePollVote {
  func resolvingOptionText(_ optionText: String?) -> MessagePollVote {
    guard self.optionText == nil, let optionText, !optionText.isEmpty else {
      return self
    }
    return MessagePollVote(
      optionID: optionID,
      optionText: optionText,
      participant: participant,
      eventType: eventType,
      serverTime: serverTime
    )
  }
}

extension MessagePollEvent {
  func resolvingVoteOptionTexts(_ optionTextsByID: [String: String]) -> MessagePollEvent {
    guard kind == .vote, !optionTextsByID.isEmpty else { return self }
    let resolvedVote = vote.map { vote in
      vote.resolvingOptionText(optionTextsByID[vote.optionID])
    }
    let resolvedVotes = votes?.map { vote in
      vote.resolvingOptionText(optionTextsByID[vote.optionID])
    }
    return MessagePollEvent(
      kind: kind,
      pollGUID: pollGUID,
      question: question,
      options: options,
      vote: resolvedVote,
      votes: resolvedVotes,
      originalGUID: originalGUID,
      creator: creator,
      participants: participants,
      metadata: metadata
    )
  }

  func resolvingPollReference(pollGUID: String?, originalGUID: String?) -> MessagePollEvent {
    if self.pollGUID == pollGUID, self.originalGUID == originalGUID {
      return self
    }
    return MessagePollEvent(
      kind: kind,
      pollGUID: pollGUID,
      question: question,
      options: options,
      vote: vote,
      votes: votes,
      originalGUID: originalGUID,
      creator: creator,
      participants: participants,
      metadata: metadata
    )
  }

  /// Returns a copy with `question` filled in. Used to backfill a native poll's
  /// empty title (item.title) from its caption message so the poll is
  /// self-describing to consumers.
  func withQuestion(_ newQuestion: String) -> MessagePollEvent {
    MessagePollEvent(
      kind: kind,
      pollGUID: pollGUID,
      question: newQuestion,
      options: options,
      vote: vote,
      votes: votes,
      originalGUID: originalGUID,
      creator: creator,
      participants: participants,
      metadata: metadata
    )
  }
}
