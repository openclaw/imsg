import Foundation
import SQLite

extension MessageStore {
  public func maxRowID() throws -> Int64 {
    return try withConnection { db in
      let value = try db.scalar("SELECT MAX(ROWID) FROM message")
      return int64Value(value) ?? 0
    }
  }

  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    return try messages(chatID: chatID, limit: limit, filter: nil)
  }

  public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
    guard limit > 0 else { return [] }
    var physicalLimit = limit

    return try withConnection { db in
      while true {
        let query = ChatMessagesQuery(
          store: self,
          chatID: ChatID(rawValue: chatID),
          limit: physicalLimit,
          filter: filter
        )
        var messages: [Message] = []
        var parentCache: ReplyParentCache = [:]
        var pollOptionCache = PollOptionTextCache()
        let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
        while let row = try rows.failableNext() {
          let decoded = try decodeMessageRow(
            row,
            columns: query.selection.columns,
            fallbackChatID: query.fallbackChatID
          )
          messages.append(
            try message(
              from: decoded,
              db,
              parentCache: &parentCache,
              pollOptionCache: &pollOptionCache
            ))
        }
        var usedFallbackReplacement = false
        let coalesced = try coalesceURLPreviewMessages(
          messages,
          validateExistingCoalescence: { text, preview in
            try self.precedingTextMessageForURLPreview(preview, db: db)?.rowID == text.rowID
          },
          fallbackForUnmatchedPreview: { preview in
            guard let previous = try self.precedingTextMessageForURLPreview(preview, db: db) else {
              return nil
            }
            if let filter, !filter.allows(previous) {
              return nil
            }
            return .replace(previous)
          },
          fallbackReplacementUsed: {
            usedFallbackReplacement = true
          }
        ).sorted(by: messageHistoryNewestFirst)

        if messages.count < physicalLimit || (coalesced.count >= limit && !usedFallbackReplacement)
        {
          return Array(coalesced.prefix(limit))
        }
        guard let nextLimit = nextHistoryPhysicalLimit(after: physicalLimit) else {
          return Array(coalesced.prefix(limit))
        }
        physicalLimit = nextLimit
      }
    }
  }

  private func nextHistoryPhysicalLimit(after current: Int) -> Int? {
    guard current > 0, current <= Int.max / 2 else { return nil }
    return current * 2
  }

  private func messageHistoryNewestFirst(_ lhs: Message, _ rhs: Message) -> Bool {
    if lhs.date == rhs.date {
      return lhs.rowID > rhs.rowID
    }
    return lhs.date > rhs.date
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    return try messagesAfter(
      afterRowID: afterRowID,
      chatID: chatID,
      limit: limit,
      includeReactions: false
    )
  }

  public func messagesAfter(
    afterRowID: Int64,
    chatID: Int64?,
    limit: Int,
    includeReactions: Bool
  ) throws -> [Message] {
    guard limit > 0 else { return [] }
    var cursor = afterRowID
    while true {
      let batch = try messagesAfterBatch(
        afterRowID: cursor,
        chatID: chatID,
        limit: limit,
        includeReactions: includeReactions
      )
      if !batch.messages.isEmpty {
        return batch.messages
      }
      guard batch.maxScannedRowID > cursor else {
        return []
      }
      cursor = batch.maxScannedRowID
    }
  }

  func messagesAfterBatch(
    afterRowID: Int64,
    chatID: Int64?,
    limit: Int,
    includeReactions: Bool
  ) throws -> MessagesAfterBatch {
    let query = MessagesAfterQuery(
      store: self,
      afterRowID: MessageID(rawValue: afterRowID),
      chatID: chatID.map { ChatID(rawValue: $0) },
      limit: limit,
      includeReactions: includeReactions
    )

    return try withConnection { db in
      var messages: [Message] = []
      var parentCache: ReplyParentCache = [:]
      var pollOptionCache = PollOptionTextCache()
      var maxScannedRowID = afterRowID

      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
        maxScannedRowID = max(maxScannedRowID, decoded.rowID)
        messages.append(
          try message(
            from: decoded,
            db,
            parentCache: &parentCache,
            pollOptionCache: &pollOptionCache
          ))
      }
      let coalesced = try coalesceURLPreviewMessages(
        messages,
        validateExistingCoalescence: { text, preview in
          try self.precedingTextMessageForURLPreview(preview, db: db)?.rowID == text.rowID
        },
        fallbackForUnmatchedPreview: { preview in
          guard try self.precedingTextMessageForURLPreview(preview, db: db) != nil else {
            return nil
          }
          return .suppress
        }
      )
      let visibleMessages = coalesced.filter { message in
        guard isURLPreviewBalloon(message) else { return true }
        return !shouldSkipURLBalloonDuplicate(
          chatID: message.chatID,
          sender: message.sender,
          text: message.text,
          isFromMe: message.isFromMe,
          date: message.date,
          rowID: message.rowID
        )
      }
      return MessagesAfterBatch(messages: visibleMessages, maxScannedRowID: maxScannedRowID)
    }
  }

  public func latestSentMessage(matchingText text: String, chatID: Int64?, since date: Date)
    throws -> Message?
  {
    guard !text.isEmpty else { return nil }

    let query = LatestSentMessageQuery(
      store: self,
      text: text,
      chatID: chatID.map { ChatID(rawValue: $0) },
      since: date
    )

    return try withConnection { db in
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      var pollOptionCache = PollOptionTextCache()
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
        guard decoded.text == text else { continue }
        let poll = try enrichedPollEvent(
          decoded.poll,
          db: db,
          cache: &pollOptionCache
        )

        let replyToGUID = routedReplyToGUID(decoded)
        let threadOriginatorGUID =
          decoded.threadOriginatorGUID.isEmpty ? nil : decoded.threadOriginatorGUID
        let threadOriginatorPart =
          decoded.threadOriginatorPart.isEmpty ? nil : decoded.threadOriginatorPart
        var parentCache: ReplyParentCache = [:]
        let parent = enrichedReplyContext(
          db,
          replyToGUID: replyToGUID,
          threadOriginatorGUID: threadOriginatorGUID,
          cache: &parentCache
        )
        return Message(
          rowID: decoded.rowID,
          chatID: decoded.chatID,
          sender: decoded.sender,
          text: decoded.text,
          date: decoded.date,
          isFromMe: decoded.isFromMe,
          service: decoded.service,
          handleID: decoded.handleID,
          attachmentsCount: decoded.attachments,
          guid: decoded.guid,
          routing: Message.RoutingMetadata(
            replyToGUID: replyToGUID,
            threadOriginatorGUID: threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart,
            destinationCallerID: decoded.destinationCallerID.isEmpty
              ? nil : decoded.destinationCallerID,
            replyToText: parent?.text,
            replyToSender: parent?.sender
          ),
          balloonBundleID: decoded.balloonBundleID.isEmpty ? nil : decoded.balloonBundleID,
          poll: poll
        )
      }
      return nil
    }
  }

  public func messageSendStatus(guid: String) throws -> MessageSendStatus? {
    let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    return try withConnection { db in
      let columns = MessageStore.tableColumns(connection: db, table: "message")
      func column(_ name: String, defaultValue: String) -> String {
        columns.contains(name.lowercased()) ? "m.\(name)" : defaultValue
      }

      let sql = """
        SELECT m.ROWID AS message_rowid,
               \(column("guid", defaultValue: "''")) AS guid,
               \(column("service", defaultValue: "''")) AS service,
               \(column("error", defaultValue: "0")) AS error,
               \(column("date_delivered", defaultValue: "0")) AS date_delivered,
               \(column("date_read", defaultValue: "0")) AS date_read,
               \(column("is_sent", defaultValue: "0")) AS is_sent,
               \(column("is_delivered", defaultValue: "0")) AS is_delivered,
               \(column("is_finished", defaultValue: "0")) AS is_finished,
               \(column("is_delayed", defaultValue: "0")) AS is_delayed,
               \(column("is_prepared", defaultValue: "0")) AS is_prepared,
               \(column("is_pending_satellite_send", defaultValue: "0")) AS is_pending_satellite_send,
               \(column("was_downgraded", defaultValue: "0")) AS was_downgraded
        FROM message m
        WHERE \(column("guid", defaultValue: "''")) = ?
        ORDER BY m.ROWID DESC
        LIMIT 1
        """
      let rows = try db.prepareRowIterator(sql, bindings: [trimmed])
      guard let row = try rows.failableNext() else { return nil }
      return try decodeMessageSendStatus(row)
    }
  }

  func decodeMessageRow(
    _ row: Row,
    columns: MessageRowColumns,
    fallbackChatID: Int64?
  ) throws -> DecodedMessageRow {
    let rowID = try int64Value(row, columns.rowID) ?? 0
    let resolvedChatID =
      try columns.chatID.flatMap { try int64Value(row, $0) } ?? fallbackChatID ?? 0
    let handleID = try int64Value(row, columns.handleID)
    let sender = try stringValue(row, columns.sender)
    let text = try stringValue(row, columns.text)
    let date = try appleDate(from: int64Value(row, columns.date))
    let isFromMe = try boolValue(row, columns.isFromMe)
    let service = try stringValue(row, columns.service)
    let isAudioMessage = try boolValue(row, columns.isAudioMessage)
    let destinationCallerID = try stringValue(row, columns.destinationCallerID)
    let guid = try stringValue(row, columns.guid)
    let associatedGUID = try stringValue(row, columns.associatedGUID)
    let associatedType = try intValue(row, columns.associatedType)
    let attachments = try intValue(row, columns.attachments) ?? 0
    let body = try dataValue(row, columns.body)
    let threadOriginatorGUID = try stringValue(row, columns.threadOriginatorGUID)
    let threadOriginatorPart = try stringValue(row, columns.threadOriginatorPart)
    let databaseReplyToGUID = try stringValue(row, columns.replyToGUID)
    let balloonBundleID = try stringValue(row, columns.balloonBundleID)

    var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
    if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
      resolvedText = transcription
    }

    var resolvedSender = sender
    if resolvedSender.isEmpty && !destinationCallerID.isEmpty {
      resolvedSender = destinationCallerID
    }

    let poll: MessagePollEvent?
    if MessagePollDecoder.isPollCandidate(
      balloonBundleID: balloonBundleID,
      associatedMessageType: associatedType
    ) {
      poll = MessagePollDecoder.decode(
        balloonBundleID: balloonBundleID,
        payloadData: try dataValue(row, columns.payloadData),
        messageSummaryInfo: try dataValue(row, columns.messageSummaryInfo),
        associatedMessageType: associatedType,
        associatedMessageGUID: associatedGUID,
        messageGUID: guid,
        sender: resolvedSender
      )
    } else {
      poll = nil
    }

    return DecodedMessageRow(
      rowID: rowID,
      chatID: resolvedChatID,
      handleID: handleID,
      sender: resolvedSender,
      text: resolvedText,
      date: date,
      isFromMe: isFromMe,
      service: service,
      destinationCallerID: destinationCallerID,
      guid: guid,
      associatedGUID: associatedGUID,
      associatedType: associatedType,
      attachments: attachments,
      threadOriginatorGUID: threadOriginatorGUID,
      threadOriginatorPart: threadOriginatorPart,
      databaseReplyToGUID: databaseReplyToGUID,
      balloonBundleID: balloonBundleID,
      poll: poll
    )
  }

  func decodeMessageSendStatus(_ row: Row) throws -> MessageSendStatus {
    let deliveredRaw = try int64Value(row, "date_delivered")
    let readRaw = try int64Value(row, "date_read")
    return MessageSendStatus(
      rowID: try int64Value(row, "message_rowid") ?? 0,
      guid: try stringValue(row, "guid"),
      service: try stringValue(row, "service"),
      error: try intValue(row, "error") ?? 0,
      dateDelivered: deliveredRaw.flatMap { $0 > 0 ? appleDate(from: $0) : nil },
      dateRead: readRaw.flatMap { $0 > 0 ? appleDate(from: $0) : nil },
      isSent: (try intValue(row, "is_sent") ?? 0) != 0,
      isDelivered: (try intValue(row, "is_delivered") ?? 0) != 0,
      isFinished: (try intValue(row, "is_finished") ?? 0) != 0,
      isDelayed: (try intValue(row, "is_delayed") ?? 0) != 0,
      isPrepared: (try intValue(row, "is_prepared") ?? 0) != 0,
      isPendingSatelliteSend: (try intValue(row, "is_pending_satellite_send") ?? 0) != 0,
      wasDowngraded: (try intValue(row, "was_downgraded") ?? 0) != 0
    )
  }

  func routedReplyToGUID(_ row: DecodedMessageRow) -> String? {
    if let associatedType = row.associatedType, ReactionType.isReaction(associatedType) {
      return nil
    }
    let databaseReplyToGUID = normalizeAssociatedGUID(row.databaseReplyToGUID)
    if !databaseReplyToGUID.isEmpty {
      return databaseReplyToGUID
    }
    return replyToGUID(
      associatedGuid: row.associatedGUID,
      associatedType: row.associatedType
    )
  }
}
