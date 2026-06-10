import Foundation

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

struct MessagesAfterBatch {
  let messages: [Message]
  let maxScannedRowID: Int64
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
