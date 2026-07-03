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

    let sourcePollGUID = try sourcePollGUID(forAny: candidateGUIDs, db: db) ?? pollGUID
    let optionTexts = try pollOptionTextsByID(
      pollGUID: sourcePollGUID,
      db: db,
      cache: &cache
    )
    let resolvedPoll = poll.resolvingVoteOptionTexts(optionTexts)
    return resolvedPoll.resolvingPollReference(
      pollGUID: sourcePollGUID,
      originalGUID: sourcePollGUID
    )
  }

  /// Ordered options of the poll identified by `guid`, decoded from its
  /// creation message and any native option update rows. Used by `poll vote`
  /// to resolve a 1-based option index or option text into the stable
  /// optionIdentifier the bridge needs.
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
    let sql: String
    let bindings: [Binding?]
    if schema.hasReactionColumns {
      sql = """
        SELECT \(selection.selectList)
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.guid = ?
           OR (
             m.associated_message_type = ?
             AND (
               m.associated_message_guid = ?
               OR m.associated_message_guid LIKE '%/' || ?
             )
           )
        ORDER BY m.date ASC, m.ROWID ASC
        """
      bindings = [guid, MessagePollDecoder.updateAssociatedMessageType, guid, guid]
    } else {
      sql = """
        SELECT \(selection.selectList)
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.guid = ?
        ORDER BY m.date ASC, m.ROWID ASC
        """
      bindings = [guid]
    }
    let rows = try db.prepareRowIterator(
      sql,
      bindings: bindings)
    var options: [MessagePollOption] = []
    var seenIDs = Set<String>()
    while let row = try rows.failableNext() {
      let decoded = try decodeMessageRow(
        row,
        columns: selection.columns,
        fallbackChatID: nil
      )
      for option in decoded.poll?.options ?? [] where seenIDs.insert(option.id).inserted {
        options.append(option)
      }
    }
    return options
  }

  private func sourcePollGUID(forAny candidates: [String], db: Connection) throws -> String? {
    guard schema.hasReactionColumns else { return nil }
    for candidate in candidates {
      if let source = try sourcePollGUID(forUpdateRow: candidate, db: db) {
        return source
      }
    }
    return candidates.first
  }

  private func sourcePollGUID(forUpdateRow guid: String, db: Connection) throws -> String? {
    let rows = try db.prepareRowIterator(
      """
      SELECT associated_message_guid
      FROM message
      WHERE guid = ?
        AND associated_message_type = ?
        AND IFNULL(associated_message_guid, '') != ''
      LIMIT 1
      """,
      bindings: [guid, MessagePollDecoder.updateAssociatedMessageType]
    )
    guard
      let row = try rows.failableNext(),
      let associatedGUID = try row.get(Expression<String?>("associated_message_guid"))
    else {
      return nil
    }

    let normalized = normalizeAssociatedGUID(associatedGUID)
    return normalized.isEmpty ? nil : normalized
  }
}
