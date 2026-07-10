import SQLite

struct MessageStoreSchema: Sendable {
  let hasAttributedBody: Bool
  let hasReactionColumns: Bool
  let hasThreadOriginatorGUIDColumn: Bool
  let hasThreadOriginatorPartColumn: Bool
  let hasDestinationCallerID: Bool
  let hasAudioMessageColumn: Bool
  let hasAttachmentUserInfo: Bool
  let hasBalloonBundleIDColumn: Bool
  let hasPayloadDataColumn: Bool
  let hasMessageSummaryInfoColumn: Bool
  let hasReplyToGUIDColumn: Bool
  let hasScheduleTypeColumn: Bool
  let hasScheduleStateColumn: Bool
  let hasChatMessageJoinMessageDateColumn: Bool
  let hasChatAccountIDColumn: Bool
  let hasChatAccountLoginColumn: Bool
  let hasChatLastAddressedHandleColumn: Bool
  let hasIsReadColumn: Bool
  let hasDateReadColumn: Bool

  init(connection: Connection) {
    let messageColumns = MessageStore.tableColumns(connection: connection, table: "message")
    let attachmentColumns = MessageStore.tableColumns(connection: connection, table: "attachment")
    let chatMessageJoinColumns = MessageStore.tableColumns(
      connection: connection,
      table: "chat_message_join"
    )
    let chatColumns = MessageStore.tableColumns(connection: connection, table: "chat")

    self.hasAttributedBody = messageColumns.contains("attributedbody")
    self.hasReactionColumns = MessageStore.reactionColumnsPresent(in: messageColumns)
    self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
    self.hasThreadOriginatorPartColumn = messageColumns.contains("thread_originator_part")
    self.hasDestinationCallerID = messageColumns.contains("destination_caller_id")
    self.hasAudioMessageColumn = messageColumns.contains("is_audio_message")
    self.hasAttachmentUserInfo = attachmentColumns.contains("user_info")
    self.hasBalloonBundleIDColumn = messageColumns.contains("balloon_bundle_id")
    self.hasPayloadDataColumn = messageColumns.contains("payload_data")
    self.hasMessageSummaryInfoColumn = messageColumns.contains("message_summary_info")
    self.hasReplyToGUIDColumn = messageColumns.contains("reply_to_guid")
    self.hasScheduleTypeColumn = messageColumns.contains("schedule_type")
    self.hasScheduleStateColumn = messageColumns.contains("schedule_state")
    self.hasChatMessageJoinMessageDateColumn = chatMessageJoinColumns.contains("message_date")
    self.hasChatAccountIDColumn = chatColumns.contains("account_id")
    self.hasChatAccountLoginColumn = chatColumns.contains("account_login")
    self.hasChatLastAddressedHandleColumn = chatColumns.contains("last_addressed_handle")
    self.hasIsReadColumn = messageColumns.contains("is_read")
    self.hasDateReadColumn = messageColumns.contains("date_read")
  }

  init(
    base: MessageStoreSchema,
    hasAttributedBody: Bool? = nil,
    hasReactionColumns: Bool? = nil,
    hasThreadOriginatorGUIDColumn: Bool? = nil,
    hasThreadOriginatorPartColumn: Bool? = nil,
    hasDestinationCallerID: Bool? = nil,
    hasAudioMessageColumn: Bool? = nil,
    hasAttachmentUserInfo: Bool? = nil,
    hasBalloonBundleIDColumn: Bool? = nil,
    hasPayloadDataColumn: Bool? = nil,
    hasMessageSummaryInfoColumn: Bool? = nil,
    hasReplyToGUIDColumn: Bool? = nil,
    hasChatMessageJoinMessageDateColumn: Bool? = nil,
    hasChatAccountIDColumn: Bool? = nil,
    hasChatAccountLoginColumn: Bool? = nil,
    hasChatLastAddressedHandleColumn: Bool? = nil,
    hasIsReadColumn: Bool? = nil,
    hasDateReadColumn: Bool? = nil
  ) {
    self.hasAttributedBody = hasAttributedBody ?? base.hasAttributedBody
    self.hasReactionColumns = hasReactionColumns ?? base.hasReactionColumns
    self.hasThreadOriginatorGUIDColumn =
      hasThreadOriginatorGUIDColumn ?? base.hasThreadOriginatorGUIDColumn
    self.hasThreadOriginatorPartColumn =
      hasThreadOriginatorPartColumn ?? base.hasThreadOriginatorPartColumn
    self.hasDestinationCallerID = hasDestinationCallerID ?? base.hasDestinationCallerID
    self.hasAudioMessageColumn = hasAudioMessageColumn ?? base.hasAudioMessageColumn
    self.hasAttachmentUserInfo = hasAttachmentUserInfo ?? base.hasAttachmentUserInfo
    self.hasBalloonBundleIDColumn = hasBalloonBundleIDColumn ?? base.hasBalloonBundleIDColumn
    self.hasPayloadDataColumn = hasPayloadDataColumn ?? base.hasPayloadDataColumn
    self.hasMessageSummaryInfoColumn =
      hasMessageSummaryInfoColumn ?? base.hasMessageSummaryInfoColumn
    self.hasReplyToGUIDColumn = hasReplyToGUIDColumn ?? base.hasReplyToGUIDColumn
    self.hasScheduleTypeColumn = base.hasScheduleTypeColumn
    self.hasScheduleStateColumn = base.hasScheduleStateColumn
    self.hasChatMessageJoinMessageDateColumn =
      hasChatMessageJoinMessageDateColumn ?? base.hasChatMessageJoinMessageDateColumn
    self.hasChatAccountIDColumn = hasChatAccountIDColumn ?? base.hasChatAccountIDColumn
    self.hasChatAccountLoginColumn = hasChatAccountLoginColumn ?? base.hasChatAccountLoginColumn
    self.hasChatLastAddressedHandleColumn =
      hasChatLastAddressedHandleColumn ?? base.hasChatLastAddressedHandleColumn
    self.hasIsReadColumn = hasIsReadColumn ?? base.hasIsReadColumn
    self.hasDateReadColumn = hasDateReadColumn ?? base.hasDateReadColumn
  }
}
