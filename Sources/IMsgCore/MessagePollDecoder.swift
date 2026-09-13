import Foundation

public enum MessagePollDecoder {
  public static let pollsBundleIdentifier = "com.apple.messages.Polls"
  static let updateAssociatedMessageType = 2
  static let voteAssociatedMessageType = 4000

  public static func isPollsBalloonBundleID(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if value == pollsBundleIdentifier { return true }
    return value.split(separator: ":").last.map(String.init) == pollsBundleIdentifier
  }

  static func isPollCandidate(balloonBundleID: String, associatedMessageType: Int?) -> Bool {
    isPollsBalloonBundleID(balloonBundleID)
      || associatedMessageType == voteAssociatedMessageType
  }

  public static func decode(
    balloonBundleID: String,
    payloadData: Data,
    messageSummaryInfo: Data,
    associatedMessageType: Int?,
    associatedMessageGUID: String,
    messageGUID: String,
    sender: String
  ) -> MessagePollEvent? {
    let isPollBundle = isPollsBalloonBundleID(balloonBundleID)
    let isVoteAssociation = associatedMessageType == voteAssociatedMessageType
    guard isPollBundle || isVoteAssociation else { return nil }

    let scan = PollPayloadScan(payloadData: payloadData, summaryData: messageSummaryInfo)
    let facts = PollFacts(objects: scan.objects)
    let hasPollPayloadEvidence = !facts.votes.isEmpty || facts.hasEmptyVotes || scan.hasPollURLHint
    guard isPollBundle || hasPollPayloadEvidence else { return nil }

    let metadata = MessagePollMetadata(
      bundleID: balloonBundleID.isEmpty ? nil : balloonBundleID,
      associatedMessageType: associatedMessageType,
      payloadBytes: payloadData.isEmpty ? nil : payloadData.count,
      summaryBytes: messageSummaryInfo.isEmpty ? nil : messageSummaryInfo.count,
      urlScheme: scan.urlScheme,
      urlHost: scan.urlHost,
      queryKeys: scan.queryKeys.isEmpty ? nil : Array(scan.queryKeys).sorted()
    )

    let originalGUID = normalizedAssociatedGUID(associatedMessageGUID)
    let senderHandle = sender.isEmpty ? nil : sender
    let votes = facts.votes.map { vote in
      MessagePollVote(
        optionID: vote.optionID,
        participant: vote.participant ?? senderHandle,
        eventType: vote.eventType,
        serverTime: vote.serverTime
      )
    }
    var participantHandles = facts.participants
    if let creator = facts.creator { participantHandles.append(creator) }
    participantHandles.append(contentsOf: votes.compactMap { $0.participant })
    let participants = sortedUnique(participantHandles)

    if isVoteAssociation || !votes.isEmpty {
      let pollGUID = firstNonEmpty(facts.pollGUID, originalGUID, messageGUID)
      return MessagePollEvent(
        kind: votes.isEmpty && !facts.hasEmptyVotes ? .unknown : .vote,
        pollGUID: pollGUID,
        question: facts.question,
        options: facts.options,
        vote: votes.first,
        votes: votes,
        originalGUID: originalGUID,
        creator: facts.creator,
        participants: participants,
        metadata: metadata
      )
    }

    if facts.question != nil || !facts.options.isEmpty {
      let creator = facts.creator ?? senderHandle
      var creationParticipants = participantHandles
      if let creator { creationParticipants.append(creator) }
      let updateOriginalGUID =
        associatedMessageType == updateAssociatedMessageType ? originalGUID : nil
      return MessagePollEvent(
        kind: .created,
        pollGUID: firstNonEmpty(facts.pollGUID, messageGUID),
        question: facts.question,
        options: facts.options,
        originalGUID: updateOriginalGUID,
        creator: creator,
        participants: sortedUnique(creationParticipants),
        metadata: metadata
      )
    }

    return MessagePollEvent(
      kind: .unknown,
      pollGUID: firstNonEmpty(facts.pollGUID, originalGUID, messageGUID),
      originalGUID: originalGUID,
      creator: facts.creator,
      participants: participants,
      metadata: metadata
    )
  }

  private static func normalizedAssociatedGUID(_ guid: String) -> String? {
    guard !guid.isEmpty else { return nil }
    guard let slash = guid.lastIndex(of: "/") else { return guid }
    let nextIndex = guid.index(after: slash)
    guard nextIndex < guid.endIndex else { return guid }
    return String(guid[nextIndex...])
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value, !value.isEmpty { return value }
    }
    return nil
  }

  private static func sortedUnique(_ values: [String]) -> [String]? {
    let filtered = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !filtered.isEmpty else { return nil }
    return Array(Set(filtered)).sorted()
  }
}
