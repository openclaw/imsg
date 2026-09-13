import Foundation

struct PollFacts {
  var question: String?
  var options: [MessagePollOption] = []
  var votes: [MessagePollVote] = []
  var hasEmptyVotes = false
  var pollGUID: String?
  var creator: String?
  var participants: [String] = []

  private var visitedNodes = 0

  init(objects: [Any]) {
    for object in objects {
      Self.collect(from: object, state: &self, depth: 0)
    }
  }

  private static func collect(from value: Any, state: inout PollFacts, depth: Int) {
    guard depth < 32, state.visitedNodes < 20_000 else { return }
    state.visitedNodes += 1

    if let dict = pollStringDictionary(value) {
      state.question =
        state.question
        ?? stringValue(
          in: dict,
          keys: [
            "question", "title", "prompt", "pollQuestion",
          ])
      state.pollGUID =
        state.pollGUID
        ?? stringValue(
          in: dict,
          keys: [
            "pollGUID", "pollGuid", "pollIdentifier", "pollID", "pollId", "poll_guid",
          ])
      state.creator =
        state.creator
        ?? stringValue(
          in: dict,
          keys: [
            "creatorHandle", "creator", "creatorIdentifier", "createdBy",
          ])
      if let creator = state.creator {
        state.participants.append(creator)
      }
      if let participantList = stringArrayValue(
        in: dict,
        keys: [
          "participants", "participantHandles", "participantIdentifiers",
        ])
      {
        state.participants.append(contentsOf: participantList)
      }

      let parsedOptions = options(from: dict)
      if !parsedOptions.isEmpty {
        state.appendOptions(parsedOptions)
      }

      let parsedVotes = votes(from: dict)
      if !parsedVotes.isEmpty {
        state.appendVotes(parsedVotes)
        state.participants.append(contentsOf: parsedVotes.compactMap { $0.participant })
      } else if hasEmptyVotesArray(in: dict) {
        state.hasEmptyVotes = true
      }

      for child in dict.values {
        collect(from: child, state: &state, depth: depth + 1)
      }
      return
    }

    if let array = pollArrayValue(value) {
      for child in array {
        collect(from: child, state: &state, depth: depth + 1)
      }
    }
  }

  private static func options(from dict: [String: Any]) -> [MessagePollOption] {
    guard
      let rawOptions = firstArray(
        in: dict,
        keys: [
          "orderedPollOptions", "pollOptions", "options", "choices",
        ])
    else {
      return []
    }
    return rawOptions.compactMap { option(from: $0) }
  }

  private static func option(from value: Any) -> MessagePollOption? {
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : MessagePollOption(id: trimmed, text: trimmed)
    }

    guard let dict = pollStringDictionary(value) else { return nil }
    let text = stringValue(
      in: dict,
      keys: [
        "pollOptionText", "text", "title", "label", "value",
      ])
    let identifier = stringValue(
      in: dict,
      keys: [
        "optionIdentifier", "identifier", "id", "optionID", "optionId", "option_id",
      ])

    guard let text else { return nil }
    let id = identifier ?? text
    return MessagePollOption(id: id, text: text)
  }

  private static func votes(from dict: [String: Any]) -> [MessagePollVote] {
    if let rawVotes = firstArray(
      in: dict,
      keys: [
        "votes", "pollVotes", "responses",
      ])
    {
      return rawVotes.compactMap { vote(from: $0) }
    }
    if dict["voteOptionIdentifier"] != nil, let vote = vote(from: dict) {
      return [vote]
    }
    return []
  }

  private static func hasEmptyVotesArray(in dict: [String: Any]) -> Bool {
    for key in ["votes", "pollVotes", "responses"] {
      guard let array = pollArrayValue(dict[key]) else { continue }
      if array.isEmpty { return true }
    }
    return false
  }

  private static func vote(from value: Any) -> MessagePollVote? {
    guard let dict = pollStringDictionary(value) else { return nil }
    guard
      let optionID = stringValue(
        in: dict,
        keys: [
          "voteOptionIdentifier", "optionID", "optionId", "option_id",
        ])
    else {
      return nil
    }
    let eventType =
      stringValue(in: dict, keys: ["eventType", "type", "action"])
      ?? removalEventType(in: dict)
      ?? "selected"
    return MessagePollVote(
      optionID: optionID,
      participant: stringValue(
        in: dict,
        keys: [
          "participantHandle", "participant", "participantIdentifier", "handle", "sender",
        ]),
      eventType: eventType,
      serverTime: stringValue(in: dict, keys: ["serverVoteTime", "serverTime", "timestamp"])
    )
  }

  private static func removalEventType(in dict: [String: Any]) -> String? {
    for key in ["removed", "isRemoved", "isRemoval"] {
      if let value = dict[key] as? Bool, value {
        return "removed"
      }
      if let number = dict[key] as? NSNumber, number.boolValue {
        return "removed"
      }
    }
    return nil
  }

  private static func stringValue(in dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
      guard let value = dict[key] else { continue }
      if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      } else if let number = value as? NSNumber {
        return number.stringValue
      }
    }
    return nil
  }

  private static func stringArrayValue(in dict: [String: Any], keys: [String]) -> [String]? {
    for key in keys {
      guard let array = pollArrayValue(dict[key]) else { continue }
      let values = array.compactMap { value -> String? in
        if let string = value as? String {
          let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        return nil
      }
      if !values.isEmpty { return values }
    }
    return nil
  }

  private static func firstArray(in dict: [String: Any], keys: [String]) -> [Any]? {
    for key in keys {
      if let array = pollArrayValue(dict[key]), !array.isEmpty { return array }
    }
    return nil
  }

  mutating func appendOptions(_ newOptions: [MessagePollOption]) {
    var existing = Set(options.map(\.id))
    for option in newOptions where !existing.contains(option.id) {
      options.append(option)
      existing.insert(option.id)
    }
  }

  mutating func appendVotes(_ newVotes: [MessagePollVote]) {
    var existing = Set(votes.map { "\($0.optionID)\u{1f}\($0.participant ?? "")" })
    for vote in newVotes {
      let key = "\(vote.optionID)\u{1f}\(vote.participant ?? "")"
      guard !existing.contains(key) else { continue }
      votes.append(vote)
      existing.insert(key)
    }
  }
}
