import Foundation

// swiftlint:disable file_length

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

    let scan = PayloadScan(payloadData: payloadData, summaryData: messageSummaryInfo)
    let facts = PollFacts(objects: scan.objects)
    let hasPollPayloadEvidence = !facts.votes.isEmpty || scan.hasPollURLHint
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
        kind: votes.isEmpty ? .unknown : .vote,
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

private struct PollFacts {
  var question: String?
  var options: [MessagePollOption] = []
  var votes: [MessagePollVote] = []
  var pollGUID: String?
  var creator: String?
  var participants: [String] = []

  init(objects: [Any]) {
    var state = PollFactsState()
    for object in objects {
      Self.collect(from: object, state: &state, depth: 0)
    }
    self.question = state.question
    self.options = state.options
    self.votes = state.votes
    self.pollGUID = state.pollGUID
    self.creator = state.creator
    self.participants = state.participants
  }

  private static func collect(from value: Any, state: inout PollFactsState, depth: Int) {
    guard depth < 32, state.visitedNodes < 20_000 else { return }
    state.visitedNodes += 1

    if let dict = stringDictionary(value) {
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
      }

      for child in dict.values {
        collect(from: child, state: &state, depth: depth + 1)
      }
      return
    }

    if let array = arrayValue(value) {
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
    return rawOptions.enumerated().compactMap { index, raw in
      option(from: raw, index: index)
    }
  }

  private static func option(from value: Any, index: Int) -> MessagePollOption? {
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : MessagePollOption(id: trimmed, text: trimmed)
    }

    guard let dict = stringDictionary(value) else { return nil }
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

    guard let text, !text.isEmpty else { return nil }
    let id = identifier?.isEmpty == false ? identifier! : text
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

  private static func vote(from value: Any) -> MessagePollVote? {
    guard let dict = stringDictionary(value) else { return nil }
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
      guard let array = arrayValue(dict[key]) else { continue }
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
      if let array = arrayValue(dict[key]), !array.isEmpty { return array }
    }
    return nil
  }
}

private struct PollFactsState {
  var question: String?
  var options: [MessagePollOption] = []
  var votes: [MessagePollVote] = []
  var pollGUID: String?
  var creator: String?
  var participants: [String] = []
  var visitedNodes = 0

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

private struct PayloadScan {
  var objects: [Any] = []
  var queryKeys = Set<String>()
  var urlScheme: String?
  var urlHost: String?

  init(payloadData: Data, summaryData: Data) {
    objects.append(contentsOf: PayloadScanner.objects(from: payloadData))
    objects.append(contentsOf: PayloadScanner.objects(from: summaryData))

    var facts = PayloadScannerFacts()
    for object in objects {
      PayloadScanner.collect(from: object, facts: &facts, depth: 0)
    }

    let nestedObjects = facts.data.flatMap { PayloadScanner.objects(from: $0) }
    objects.append(contentsOf: nestedObjects)
    for object in nestedObjects {
      PayloadScanner.collect(from: object, facts: &facts, depth: 0)
    }

    for string in facts.strings {
      if let url = PayloadScanner.url(from: string) {
        facts.urls.append(url)
      }
    }

    for url in facts.urls {
      captureMetadata(from: url)
      if let dataPayload = PayloadScanner.dataURLPayload(from: url) {
        objects.append(contentsOf: PayloadScanner.embeddedObjects(from: dataPayload))
      }
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        continue
      }
      for item in components.queryItems ?? [] {
        queryKeys.insert(item.name)
        guard let value = item.value else { continue }
        objects.append(contentsOf: PayloadScanner.embeddedObjects(from: value))
      }
    }
  }

  private mutating func captureMetadata(from url: URL) {
    if urlScheme == nil {
      urlScheme = url.scheme
    }
    if urlHost == nil {
      urlHost = url.host
    }
  }

  var hasPollURLHint: Bool {
    [urlScheme, urlHost].contains { value in
      value?.localizedCaseInsensitiveContains("poll") == true
    }
  }
}

private struct PayloadScannerFacts {
  var strings: [String] = []
  var urls: [URL] = []
  var data: [Data] = []
  var visitedNodes = 0
}

private enum PayloadScanner {
  static func objects(from data: Data) -> [Any] {
    guard !data.isEmpty else { return [] }
    var objects: [Any] = []

    if let object = try? NSKeyedUnarchiver.unarchivedObject(
      ofClasses: allowedArchiveClasses,
      from: data
    ) {
      objects.append(object)
    }

    if let plist = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) {
      objects.append(plist)
      if let resolved = KeyedArchiveResolver.resolve(plist) {
        objects.append(resolved)
      }
    }

    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
      objects.append(json)
    }

    if let string = String(data: data, encoding: .utf8) {
      objects.append(string)
      objects.append(contentsOf: embeddedObjects(from: string))
    }

    return objects
  }

  static func embeddedObjects(from value: String) -> [Any] {
    let decoded = value.removingPercentEncoding ?? value
    var objects: [Any] = []
    if let data = decoded.data(using: .utf8) {
      objects.append(contentsOf: structuredObjects(from: data))
    }
    if let data = base64Data(from: decoded) {
      objects.append(contentsOf: Self.objects(from: data))
    }
    return objects
  }

  static func collect(from value: Any, facts: inout PayloadScannerFacts, depth: Int) {
    guard depth < 32, facts.visitedNodes < 20_000 else { return }
    facts.visitedNodes += 1

    if let url = value as? URL {
      facts.urls.append(url)
      return
    }
    if let url = value as? NSURL {
      facts.urls.append(url as URL)
      return
    }
    if let string = value as? String {
      facts.strings.append(string)
      return
    }
    if let data = value as? Data {
      facts.data.append(data)
      return
    }
    if let dict = stringDictionary(value) {
      for child in dict.values {
        collect(from: child, facts: &facts, depth: depth + 1)
      }
      return
    }
    if let array = arrayValue(value) {
      for child in array {
        collect(from: child, facts: &facts, depth: depth + 1)
      }
    }
  }

  static func url(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 65_536,
      let components = URLComponents(string: trimmed),
      components.scheme != nil
    else {
      return nil
    }
    return components.url ?? URL(string: trimmed)
  }

  static func dataURLPayload(from url: URL) -> String? {
    guard url.scheme?.lowercased() == "data" else { return nil }
    let absolute = url.absoluteString
    guard let comma = absolute.firstIndex(of: ",") else { return nil }
    let payloadStart = absolute.index(after: comma)
    let end =
      absolute[payloadStart...].firstIndex(where: { $0 == "?" || $0 == "#" })
      ?? absolute.endIndex
    guard payloadStart < end else { return nil }
    let payload = String(absolute[payloadStart..<end])
    return payload.removingPercentEncoding ?? payload
  }

  private static func structuredObjects(from data: Data) -> [Any] {
    var objects: [Any] = []
    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
      objects.append(json)
    }
    if let plist = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) {
      objects.append(plist)
      if let resolved = KeyedArchiveResolver.resolve(plist) {
        objects.append(resolved)
      }
    }
    return objects
  }

  private static func base64Data(from value: String) -> Data? {
    let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count >= 8 else { return nil }
    guard
      compact.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "+" || character == "/"
          || character == "-" || character == "_" || character == "="
      })
    else {
      return nil
    }
    var normalized = compact.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: normalized)
  }

  private static let allowedArchiveClasses: [AnyClass] = [
    NSArray.self,
    NSDictionary.self,
    NSString.self,
    NSNumber.self,
    NSData.self,
    NSDate.self,
    NSURL.self,
    NSUUID.self,
    NSNull.self,
  ]
}

private enum KeyedArchiveResolver {
  static func resolve(_ plist: Any) -> Any? {
    guard let archive = stringDictionary(plist),
      let objects = arrayValue(archive["$objects"]),
      let top = stringDictionary(archive["$top"])
    else {
      return nil
    }
    let rootUID =
      top["root"].flatMap(uidValue)
      ?? top.values.compactMap(uidValue).first
    guard let rootUID else { return nil }
    var seen = Set<Int>()
    return resolveObject(at: rootUID, objects: objects, seen: &seen, depth: 0)
  }

  private static func resolveObject(
    at index: Int,
    objects: [Any],
    seen: inout Set<Int>,
    depth: Int
  ) -> Any? {
    guard index > 0, index < objects.count, depth < 32 else { return nil }
    if seen.contains(index) { return nil }
    seen.insert(index)
    defer { seen.remove(index) }
    return resolveValue(objects[index], objects: objects, seen: &seen, depth: depth + 1)
  }

  private static func resolveValue(
    _ value: Any,
    objects: [Any],
    seen: inout Set<Int>,
    depth: Int
  ) -> Any? {
    if let uid = uidValue(value) {
      return resolveObject(at: uid, objects: objects, seen: &seen, depth: depth + 1)
    }
    if value is NSNull { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number }
    if let data = value as? Data { return data }
    if let date = value as? Date { return date }

    if let array = arrayValue(value) {
      return array.compactMap { child in
        resolveValue(child, objects: objects, seen: &seen, depth: depth + 1)
      }
    }

    guard let dict = stringDictionary(value) else { return value }

    if let relative = dict["NS.relative"] {
      let resolvedRelative =
        resolveValue(
          relative,
          objects: objects,
          seen: &seen,
          depth: depth + 1
        ) as? String
      if let base = dict["NS.base"],
        let baseString = resolveValue(base, objects: objects, seen: &seen, depth: depth + 1)
          as? String,
        let relative = resolvedRelative,
        let baseURL = URL(string: baseString)
      {
        return URL(string: relative, relativeTo: baseURL)?.absoluteString ?? relative
      }
      return resolvedRelative
    }

    if let keys = arrayValue(dict["NS.keys"]), let values = arrayValue(dict["NS.objects"]) {
      var resolved: [String: Any] = [:]
      for (rawKey, rawValue) in zip(keys, values) {
        guard
          let key = resolveValue(rawKey, objects: objects, seen: &seen, depth: depth + 1)
            as? String
        else {
          continue
        }
        if let value = resolveValue(rawValue, objects: objects, seen: &seen, depth: depth + 1) {
          resolved[key] = value
        }
      }
      return resolved
    }

    if let values = arrayValue(dict["NS.objects"]) {
      return values.compactMap { child in
        resolveValue(child, objects: objects, seen: &seen, depth: depth + 1)
      }
    }

    var resolved: [String: Any] = [:]
    for (key, rawValue) in dict
    where key != "$class" && key != "$classes" && key != "$classname" {
      if let value = resolveValue(rawValue, objects: objects, seen: &seen, depth: depth + 1) {
        resolved[key] = value
      }
    }
    return resolved
  }

  private static func uidValue(_ value: Any) -> Int? {
    let description = String(describing: value)
    guard let marker = description.range(of: "value = ") else { return nil }
    var digits = ""
    for character in description[marker.upperBound...] {
      guard character.isNumber else { break }
      digits.append(character)
    }
    return Int(digits)
  }
}

private func arrayValue(_ value: Any?) -> [Any]? {
  guard let value else { return nil }
  if let array = value as? [Any] { return array }
  if let array = value as? NSArray { return array.map { $0 } }
  return nil
}

private func stringDictionary(_ value: Any?) -> [String: Any]? {
  guard let value else { return nil }
  if let dict = value as? [String: Any] { return dict }
  guard let dict = value as? NSDictionary else { return nil }
  var result: [String: Any] = [:]
  for (key, value) in dict {
    guard let key = key as? String else { continue }
    result[key] = value
  }
  return result
}
