import SQLite

extension MessageStore {
  func enrichedPollEvent(
    _ poll: MessagePollEvent?,
    db: Connection,
    cache: inout PollOptionTextCache
  ) throws -> MessagePollEvent? {
    guard let poll, poll.kind == .vote else { return poll }
    let candidateGUIDs = [poll.originalGUID, poll.pollGUID]
      .compactMap { value -> String? in
        guard let value else { return nil }
        let normalized = normalizeAssociatedGUID(value)
        return normalized.isEmpty ? nil : normalized
      }
    guard let pollGUID = candidateGUIDs.first else { return poll }

    let optionTexts = try pollOptionTextsByID(
      pollGUID: pollGUID,
      db: db,
      cache: &cache
    )
    return poll.resolvingVoteOptionTexts(optionTexts)
  }

  /// Ordered options of the poll identified by `guid`, decoded from its
  /// creation message. Used by `poll vote` to resolve a 1-based option index
  /// or option text into the stable optionIdentifier the bridge needs.
  public func pollOptions(guid: String) throws -> [MessagePollOption] {
    let normalized = normalizeAssociatedGUID(guid)
    let target = normalized.isEmpty ? guid : normalized
    guard !target.isEmpty else { return [] }
    return try withConnection { db in
      try decodedPollOptions(guid: target, db: db)
    }
  }

  private func pollOptionTextsByID(
    pollGUID: String,
    db: Connection,
    cache: inout PollOptionTextCache
  ) throws -> [String: String] {
    if let cached = cache.optionsByPollGUID[pollGUID] {
      return cached
    }
    if cache.missingPollGUIDs.contains(pollGUID) {
      return [:]
    }

    let options = try decodedPollOptions(guid: pollGUID, db: db)
    guard !options.isEmpty else {
      cache.missingPollGUIDs.insert(pollGUID)
      return [:]
    }

    var optionTexts: [String: String] = [:]
    for option in options where optionTexts[option.id] == nil {
      optionTexts[option.id] = option.text
    }
    cache.optionsByPollGUID[pollGUID] = optionTexts
    return optionTexts
  }

  private func decodedPollOptions(guid: String, db: Connection) throws -> [MessagePollOption] {
    let selection = MessageRowSelection(store: self, includeChatID: false)
    let sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.guid = ?
      LIMIT 1
      """
    let rows = try db.prepareRowIterator(sql, bindings: [guid])
    guard let row = try rows.failableNext() else { return [] }
    let decoded = try decodeMessageRow(
      row,
      columns: selection.columns,
      fallbackChatID: nil
    )
    return decoded.poll?.options ?? []
  }
}
