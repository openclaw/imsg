import Foundation
import SQLite

struct MessageRowColumns {
  static let balloonBundleID = "balloon_bundle_id"
  static let payloadData = "payload_data"
  static let messageSummaryInfo = "message_summary_info"

  let rowID: String
  let chatID: String?
  let handleID: String
  let sender: String
  let text: String
  let date: String
  let isFromMe: String
  let service: String
  let isAudioMessage: String
  let destinationCallerID: String
  let guid: String
  let associatedGUID: String
  let associatedType: String
  let attachments: String
  let body: String
  let threadOriginatorGUID: String
  let threadOriginatorPart: String
  let replyToGUID: String
  let balloonBundleID: String
  let payloadData: String
  let messageSummaryInfo: String

  static func message(chatID: String?) -> MessageRowColumns {
    MessageRowColumns(
      rowID: "message_rowid",
      chatID: chatID,
      handleID: "handle_id",
      sender: "sender",
      text: "text",
      date: "date",
      isFromMe: "is_from_me",
      service: "service",
      isAudioMessage: "is_audio_message",
      destinationCallerID: "destination_caller_id",
      guid: "guid",
      associatedGUID: "associated_guid",
      associatedType: "associated_type",
      attachments: "attachments",
      body: "body",
      threadOriginatorGUID: "thread_originator_guid",
      threadOriginatorPart: "thread_originator_part",
      replyToGUID: "reply_to_guid",
      balloonBundleID: MessageRowColumns.balloonBundleID,
      payloadData: MessageRowColumns.payloadData,
      messageSummaryInfo: MessageRowColumns.messageSummaryInfo
    )
  }
}

struct DecodedMessageRow {
  let rowID: Int64
  let chatID: Int64
  let handleID: Int64?
  let sender: String
  let text: String
  let date: Date
  let isFromMe: Bool
  let service: String
  let destinationCallerID: String
  let guid: String
  let associatedGUID: String
  let associatedType: Int?
  let attachments: Int
  let threadOriginatorGUID: String
  let threadOriginatorPart: String
  let databaseReplyToGUID: String
  let balloonBundleID: String
  let poll: MessagePollEvent?
}

struct PollOptionTextCache {
  var optionsByPollGUID: [String: [String: String]] = [:]
  var missingPollGUIDs = Set<String>()
}

struct MessageRowSelection {
  let selectList: String
  let columns: MessageRowColumns

  init(store: MessageStore, includeChatID: Bool) {
    let columns = MessageRowColumns.message(chatID: includeChatID ? "chat_id" : nil)
    let schema = store.schema
    let bodyColumn = schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = schema.hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = schema.hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = schema.hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn =
      schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = schema.hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn =
      schema.hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn =
      schema.hasThreadOriginatorPartColumn ? "m.thread_originator_part" : "NULL"
    let replyToColumn = schema.hasReplyToGUIDColumn ? "m.reply_to_guid" : "NULL"
    let balloonColumn = schema.hasBalloonBundleIDColumn ? "m.balloon_bundle_id" : "NULL"
    let pollCandidatePredicate = Self.pollCandidatePredicate(schema: schema)
    let payloadDataColumn =
      schema.hasPayloadDataColumn
      ? "CASE WHEN \(pollCandidatePredicate) THEN m.payload_data ELSE NULL END" : "NULL"
    let summaryInfoColumn =
      schema.hasMessageSummaryInfoColumn
      ? "CASE WHEN \(pollCandidatePredicate) THEN m.message_summary_info ELSE NULL END" : "NULL"
    let chatColumn = includeChatID ? ", cmj.chat_id AS \(columns.chatID!)" : ""

    let selectList = """
      m.ROWID AS \(columns.rowID)\(chatColumn), m.handle_id AS \(columns.handleID),
             h.id AS \(columns.sender), IFNULL(m.text, '') AS \(columns.text),
             m.date AS \(columns.date), m.is_from_me AS \(columns.isFromMe),
             m.service AS \(columns.service),
             \(audioMessageColumn) AS \(columns.isAudioMessage),
             \(destinationCallerColumn) AS \(columns.destinationCallerID),
             \(guidColumn) AS \(columns.guid), \(associatedGuidColumn) AS \(columns.associatedGUID),
             \(associatedTypeColumn) AS \(columns.associatedType),
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS \(columns.attachments),
             \(bodyColumn) AS \(columns.body),
             \(threadOriginatorColumn) AS \(columns.threadOriginatorGUID),
             \(threadOriginatorPartColumn) AS \(columns.threadOriginatorPart),
             \(replyToColumn) AS \(columns.replyToGUID),
             \(balloonColumn) AS \(columns.balloonBundleID),
             \(payloadDataColumn) AS \(columns.payloadData),
             \(summaryInfoColumn) AS \(columns.messageSummaryInfo)
      """
    self.selectList = selectList
    self.columns = columns
  }

  private static func pollCandidatePredicate(schema: MessageStoreSchema) -> String {
    let pollBundle = sqlStringLiteral(MessagePollDecoder.pollsBundleIdentifier)
    let pollBalloonPredicate =
      schema.hasBalloonBundleIDColumn
      ? "(m.balloon_bundle_id = \(pollBundle) OR m.balloon_bundle_id LIKE '%:' || \(pollBundle))"
      : "0"
    let votePredicate =
      schema.hasReactionColumns
      ? "m.associated_message_type = \(MessagePollDecoder.voteAssociatedMessageType)"
      : "0"
    return "(\(pollBalloonPredicate) OR \(votePredicate))"
  }

  private static func sqlStringLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
  }
}

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
    let query = ChatMessagesQuery(
      store: self,
      chatID: ChatID(rawValue: chatID),
      limit: limit,
      filter: filter
    )

    return try withConnection { db in
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
        let parent = enrichedReplyContext(
          db,
          replyToGUID: replyToGUID,
          threadOriginatorGUID: threadOriginatorGUID,
          cache: &parentCache
        )
        messages.append(
          Message(
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
          ))
      }
      return messages
    }
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
      let urlBalloonProvider = "com.apple.messages.URLBalloonProvider"

      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
        let poll = try enrichedPollEvent(
          decoded.poll,
          db: db,
          cache: &pollOptionCache
        )
        let balloonBundleID = try stringValue(row, MessageRowColumns.balloonBundleID)
        if balloonBundleID == urlBalloonProvider,
          shouldSkipURLBalloonDuplicate(
            chatID: decoded.chatID,
            sender: decoded.sender,
            text: decoded.text,
            isFromMe: decoded.isFromMe,
            date: decoded.date,
            rowID: decoded.rowID
          )
        {
          continue
        }

        let reaction = decodeReaction(
          associatedType: decoded.associatedType,
          associatedGUID: decoded.associatedGUID,
          text: decoded.text
        )
        let replyToGUID = routedReplyToGUID(decoded)
        let threadOriginatorGUID =
          reaction.isReaction || decoded.threadOriginatorGUID.isEmpty
          ? nil : decoded.threadOriginatorGUID
        let threadOriginatorPart =
          reaction.isReaction || decoded.threadOriginatorPart.isEmpty
          ? nil : decoded.threadOriginatorPart
        let parent =
          reaction.isReaction
          ? nil
          : enrichedReplyContext(
            db,
            replyToGUID: replyToGUID,
            threadOriginatorGUID: threadOriginatorGUID,
            cache: &parentCache
          )

        messages.append(
          Message(
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
            reaction: Message.ReactionMetadata(
              isReaction: reaction.isReaction,
              reactionType: reaction.reactionType,
              isReactionAdd: reaction.isReactionAdd,
              reactedToGUID: reaction.reactedToGUID
            ),
            poll: poll
          ))
      }
      return messages
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
