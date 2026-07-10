import SQLite

@testable import IMsgCore

enum MessageDatabaseFixture {
  struct SchemaOptions {
    var includeAttributedBody = false
    var includeReactionColumns = false
    var includeThreadOriginatorGUID = false
    var includeThreadOriginatorPart = false
    var includeDestinationCallerID = false
    var includeAudioMessage = false
    var includeBalloonBundleID = false
    var includePayloadData = false
    var includeMessageSummaryInfo = false
    var includeReplyToGUID = false
    var includeAttachmentUserInfo = false
    var includeChatMessageDate = false
    var includeChatRouting = true
    var includeChatHandleJoin = true
    var includeScheduleColumns = false
    var includeReadState = false
  }

  static func createSchema(_ db: Connection, options: SchemaOptions = SchemaOptions()) throws {
    let attributedBodyColumn = options.includeAttributedBody ? "attributedBody BLOB," : ""
    let reactionColumns =
      options.includeReactionColumns
      ? "guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER,"
      : ""
    let threadOriginatorColumn =
      options.includeThreadOriginatorGUID ? "thread_originator_guid TEXT," : ""
    let threadOriginatorPartColumn =
      options.includeThreadOriginatorPart ? "thread_originator_part TEXT," : ""
    let destinationCallerColumn =
      options.includeDestinationCallerID ? "destination_caller_id TEXT," : ""
    let audioMessageColumn = options.includeAudioMessage ? "is_audio_message INTEGER," : ""
    let balloonColumn = options.includeBalloonBundleID ? "balloon_bundle_id TEXT," : ""
    let payloadDataColumn = options.includePayloadData ? "payload_data BLOB," : ""
    let summaryInfoColumn = options.includeMessageSummaryInfo ? "message_summary_info BLOB," : ""
    let replyToColumn = options.includeReplyToGUID ? "reply_to_guid TEXT," : ""
    let scheduleColumns =
      options.includeScheduleColumns ? "schedule_type INTEGER, schedule_state INTEGER," : ""
    let readStateColumns =
      options.includeReadState
      ? "is_read INTEGER, date_read INTEGER,"
      : ""

    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        \(attributedBodyColumn)
        \(reactionColumns)
        \(threadOriginatorColumn)
        \(threadOriginatorPartColumn)
        \(destinationCallerColumn)
        \(audioMessageColumn)
        \(balloonColumn)
        \(payloadDataColumn)
        \(summaryInfoColumn)
        \(replyToColumn)
        \(scheduleColumns)
        \(readStateColumns)
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )

    let chatRoutingColumns =
      options.includeChatRouting
      ? "account_id TEXT, account_login TEXT, last_addressed_handle TEXT,"
      : ""
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT,
        \(chatRoutingColumns)
        reserved TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    if options.includeChatHandleJoin {
      try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    }
    let messageDateColumn = options.includeChatMessageDate ? ", message_date INTEGER" : ""
    try db.execute(
      "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER\(messageDateColumn));")

    let attachmentUserInfoColumn = options.includeAttachmentUserInfo ? ", user_info BLOB" : ""
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
        \(attachmentUserInfoColumn)
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE message_attachment_join (
        message_id INTEGER,
        attachment_id INTEGER
      );
      """
    )
  }
}
