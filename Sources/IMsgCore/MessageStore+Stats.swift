import Foundation
import SQLite

private struct MessageStatsAccumulator {
  private(set) var totalMessages: Int64 = 0
  private(set) var sentMessages: Int64 = 0
  private(set) var receivedMessages: Int64 = 0
  private var chats: [Int64: ChatMessageCount] = [:]
  private var senders: [String: Int64] = [:]
  private var services: [String: Int64] = [:]
  private var dates: [String: Int64] = [:]
  private var calendar: Calendar

  init(timeZone: TimeZone) {
    self.calendar = Calendar(identifier: .gregorian)
    self.calendar.locale = Locale(identifier: "en_US_POSIX")
    self.calendar.timeZone = timeZone
  }

  mutating func addGlobal(_ message: Message) {
    totalMessages += 1
    if message.isFromMe {
      sentMessages += 1
    } else {
      receivedMessages += 1
      senders[Self.bucket(message.sender), default: 0] += 1
    }
    services[Self.bucket(message.service), default: 0] += 1
    dates[day(for: message.date), default: 0] += 1
  }

  mutating func addChat(_ chat: StatsChatDimension) {
    var value = chats[chat.id] ?? ChatMessageCount(chat: chat, count: 0)
    value.count += 1
    chats[chat.id] = value
  }

  func result(timeZone: TimeZone, media: MediaStats?) -> MessageStats {
    MessageStats(
      totalMessages: totalMessages,
      sentMessages: sentMessages,
      receivedMessages: receivedMessages,
      timeZone: timeZone.identifier,
      chats: chats.values.map {
        ChatMessageStats(
          chatID: $0.chat.id,
          identifier: $0.chat.identifier,
          name: $0.chat.name,
          service: $0.chat.service,
          messageCount: $0.count
        )
      }.sorted {
        $0.messageCount == $1.messageCount
          ? $0.chatID < $1.chatID : $0.messageCount > $1.messageCount
      },
      senders: senders.map { SenderMessageStats(handle: $0.key, messageCount: $0.value) }
        .sorted {
          $0.messageCount == $1.messageCount
            ? $0.handle < $1.handle : $0.messageCount > $1.messageCount
        },
      services: services.map { ServiceMessageStats(service: $0.key, messageCount: $0.value) }
        .sorted {
          $0.messageCount == $1.messageCount
            ? $0.service < $1.service : $0.messageCount > $1.messageCount
        },
      dates: dates.map { DateMessageStats(date: $0.key, messageCount: $0.value) }
        .sorted { $0.date < $1.date },
      media: media
    )
  }

  private mutating func day(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  private static func bucket(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown" : trimmed
  }
}

private struct MediaStatsAccumulator {
  private var total = MediaCount()
  private var types: [MediaTypeKey: MediaCount] = [:]
  private var chats: [Int64: ChatMediaCount] = [:]

  mutating func addGlobal(_ attachment: StatsAttachmentRow) {
    total.attachments += 1
    total.bytes += attachment.totalBytes
    let key = MediaTypeKey(
      uti: Self.bucket(attachment.uti),
      mimeType: Self.bucket(attachment.mimeType)
    )
    var value = types[key] ?? MediaCount()
    value.attachments += 1
    value.bytes += attachment.totalBytes
    types[key] = value
  }

  mutating func addChat(_ attachment: StatsAttachmentRow) {
    var value =
      chats[attachment.chat.id]
      ?? ChatMediaCount(chat: attachment.chat, attachments: 0, bytes: 0)
    value.attachments += 1
    value.bytes += attachment.totalBytes
    chats[attachment.chat.id] = value
  }

  func result() -> MediaStats {
    MediaStats(
      totalAttachments: total.attachments,
      totalBytes: total.bytes,
      types: types.map {
        MediaTypeStats(
          uti: $0.key.uti,
          mimeType: $0.key.mimeType,
          attachmentCount: $0.value.attachments,
          totalBytes: $0.value.bytes
        )
      }.sorted {
        if $0.attachmentCount != $1.attachmentCount {
          return $0.attachmentCount > $1.attachmentCount
        }
        if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
        if $0.uti != $1.uti { return $0.uti < $1.uti }
        return $0.mimeType < $1.mimeType
      },
      chats: chats.values.map {
        ChatMediaStats(
          chatID: $0.chat.id,
          identifier: $0.chat.identifier,
          name: $0.chat.name,
          attachmentCount: $0.attachments,
          totalBytes: $0.bytes
        )
      }.sorted {
        if $0.attachmentCount != $1.attachmentCount {
          return $0.attachmentCount > $1.attachmentCount
        }
        if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
        return $0.chatID < $1.chatID
      }
    )
  }

  private static func bucket(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown" : trimmed
  }
}

extension MessageStore {
  public func messageStats(
    chatID: Int64? = nil,
    includeMedia: Bool = false,
    timeZoneIdentifier: String? = nil
  ) throws -> MessageStats {
    if let chatID, chatID <= 0 {
      throw MessageStatsError.invalidChatID(chatID)
    }
    let timeZone = try statsTimeZone(identifier: timeZoneIdentifier)

    return try withConnection { db in
      var result = MessageStats(
        totalMessages: 0,
        sentMessages: 0,
        receivedMessages: 0,
        timeZone: timeZone.identifier,
        chats: [],
        senders: [],
        services: [],
        dates: []
      )
      try db.transaction(.deferred) {
        if let chatID {
          try validateStatsChat(chatID, db: db)
        }
        var accumulator = MessageStatsAccumulator(timeZone: timeZone)
        try accumulateMessages(chatID: chatID, db: db, into: &accumulator)
        let media = includeMedia ? try accumulateMedia(chatID: chatID, db: db) : nil
        result = accumulator.result(timeZone: timeZone, media: media)
      }
      return result
    }
  }

  private func statsTimeZone(identifier: String?) throws -> TimeZone {
    guard let identifier else { return TimeZone.current }
    guard !identifier.isEmpty, let timeZone = TimeZone(identifier: identifier) else {
      throw MessageStatsError.invalidTimeZone(identifier)
    }
    return timeZone
  }

  private func validateStatsChat(_ chatID: Int64, db: Connection) throws {
    let rows = try db.prepareRowIterator(
      "SELECT 1 AS found FROM chat WHERE ROWID = ? LIMIT 1",
      bindings: [chatID]
    )
    guard try rows.failableNext() != nil else {
      throw MessageStatsError.chatNotFound(chatID)
    }
  }

  private func accumulateMessages(
    chatID: Int64?,
    db: Connection,
    into accumulator: inout MessageStatsAccumulator
  ) throws {
    let suppressedPreviews = try suppressedStatsURLPreviews(chatID: chatID, db: db)
    let query = StatsMessageQuery(schema: schema, chatID: chatID)
    let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
    var group: [StatsMessageRow] = []
    var groupRowID: Int64?

    while let row = try rows.failableNext() {
      let decoded = try decodeStatsMessageRow(row)
      if let groupRowID, groupRowID != decoded.message.rowID {
        accumulateMessageGroup(group, suppressedPreviews: suppressedPreviews, into: &accumulator)
        group.removeAll(keepingCapacity: true)
      }
      groupRowID = decoded.message.rowID
      group.append(decoded)
    }
    accumulateMessageGroup(group, suppressedPreviews: suppressedPreviews, into: &accumulator)
  }

  private func accumulateMessageGroup(
    _ rows: [StatsMessageRow],
    suppressedPreviews: Set<StatsMessageKey>,
    into accumulator: inout MessageStatsAccumulator
  ) {
    var globalMessage: Message?
    for row in rows {
      let key = StatsMessageKey(chatID: row.message.chatID, rowID: row.message.rowID)
      guard !suppressedPreviews.contains(key) else { continue }
      accumulator.addChat(row.chat)
      if globalMessage == nil { globalMessage = row.message }
    }
    if let globalMessage {
      accumulator.addGlobal(globalMessage)
    }
  }

  private func decodeStatsMessageRow(_ row: Row) throws -> StatsMessageRow {
    let rowID = try int64Value(row, "message_rowid") ?? 0
    let chatID = try int64Value(row, "chat_id") ?? 0
    let handleID = try int64Value(row, "handle_id")
    let rawText = try stringValue(row, "text")
    let text =
      rawText.isEmpty
      ? TypedStreamParser.parseAttributedBody(try dataValue(row, "body")) : rawText
    let isFromMe = try boolValue(row, "is_from_me")
    let destinationCallerID = try stringValue(row, "destination_caller_id")
    let rawSender = try stringValue(row, "sender")
    let sender = rawSender.isEmpty ? destinationCallerID : rawSender
    let service = try stringValue(row, "message_service").nilIfEmpty ?? "unknown"
    let message = Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: text,
      date: appleDate(from: try int64Value(row, "message_date")),
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: 0,
      balloonBundleID: try stringValue(row, "balloon_bundle_id").nilIfEmpty
    )
    return StatsMessageRow(
      message: message,
      chat: StatsChatDimension(
        id: chatID,
        identifier: try stringValue(row, "chat_identifier"),
        name: try stringValue(row, "chat_name").nilIfEmpty ?? "unknown",
        service: try stringValue(row, "chat_service").nilIfEmpty ?? "unknown"
      )
    )
  }

  private func suppressedStatsURLPreviews(
    chatID: Int64?,
    db: Connection
  ) throws -> Set<StatsMessageKey> {
    guard schema.hasBalloonBundleIDColumn else { return [] }
    let query = StatsPreviewQuery(schema: schema, chatID: chatID)
    let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
    var result = Set<StatsMessageKey>()
    var coalescedBaseByPreview = [StatsMessageKey: Message]()
    while let row = try rows.failableNext() {
      let chatID = try int64Value(row, "chat_id") ?? 0
      guard let preview = try decodeStatsPreviewMessage(row, prefix: "preview", chatID: chatID),
        let immediatePrevious = try decodeStatsPreviewMessage(
          row,
          prefix: "previous",
          chatID: chatID
        )
      else {
        continue
      }
      let previousKey = StatsMessageKey(chatID: chatID, rowID: immediatePrevious.rowID)
      let candidate = coalescedBaseByPreview[previousKey] ?? immediatePrevious
      guard canCoalesceURLPreview(textMessage: candidate, previewMessage: preview) else {
        continue
      }
      let previewKey = StatsMessageKey(chatID: chatID, rowID: preview.rowID)
      result.insert(previewKey)
      // History skips a preview after coalescing it. Carry the original text row
      // forward so a run of previews is evaluated against the same logical message.
      coalescedBaseByPreview[previewKey] = candidate
    }
    return result
  }

  private func decodeStatsPreviewMessage(
    _ row: Row,
    prefix: String,
    chatID: Int64
  ) throws -> Message? {
    guard let rowID = try int64Value(row, "\(prefix)_rowid") else { return nil }
    let rawText = try stringValue(row, "\(prefix)_text")
    let text =
      rawText.isEmpty
      ? TypedStreamParser.parseAttributedBody(try dataValue(row, "\(prefix)_body")) : rawText
    let rawSender = try stringValue(row, "\(prefix)_sender")
    let destination = try stringValue(row, "\(prefix)_destination_caller_id")
    return Message(
      rowID: rowID,
      chatID: chatID,
      sender: rawSender.isEmpty ? destination : rawSender,
      text: text,
      date: appleDate(from: try int64Value(row, "\(prefix)_date")),
      isFromMe: try boolValue(row, "\(prefix)_is_from_me"),
      service: try stringValue(row, "\(prefix)_service").nilIfEmpty ?? "unknown",
      handleID: try int64Value(row, "\(prefix)_handle_id"),
      attachmentsCount: 0,
      balloonBundleID: try stringValue(row, "\(prefix)_balloon_bundle_id").nilIfEmpty
    )
  }

  private func accumulateMedia(chatID: Int64?, db: Connection) throws -> MediaStats {
    let requiredTables = ["attachment", "message_attachment_join"]
    guard try requiredTables.allSatisfy({ try statsTableExists($0, db: db) }) else {
      throw MessageStatsError.mediaUnavailable
    }

    let query = StatsMediaQuery(schema: schema, chatID: chatID)
    let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
    var accumulator = MediaStatsAccumulator()
    var group: [StatsAttachmentRow] = []
    var groupID: Int64?

    while let row = try rows.failableNext() {
      let decoded = try decodeStatsAttachmentRow(row)
      if let groupID, groupID != decoded.id {
        accumulateAttachmentGroup(group, into: &accumulator)
        group.removeAll(keepingCapacity: true)
      }
      groupID = decoded.id
      group.append(decoded)
    }
    accumulateAttachmentGroup(group, into: &accumulator)
    return accumulator.result()
  }

  private func decodeStatsAttachmentRow(_ row: Row) throws -> StatsAttachmentRow {
    StatsAttachmentRow(
      id: try int64Value(row, "attachment_id") ?? 0,
      chat: StatsChatDimension(
        id: try int64Value(row, "chat_id") ?? 0,
        identifier: try stringValue(row, "chat_identifier"),
        name: try stringValue(row, "chat_name").nilIfEmpty ?? "unknown",
        service: ""
      ),
      uti: try stringValue(row, "uti"),
      mimeType: try stringValue(row, "mime_type"),
      totalBytes: max(try int64Value(row, "total_bytes") ?? 0, 0)
    )
  }

  private func accumulateAttachmentGroup(
    _ rows: [StatsAttachmentRow],
    into accumulator: inout MediaStatsAccumulator
  ) {
    guard let first = rows.first else { return }
    accumulator.addGlobal(first)
    for row in rows {
      accumulator.addChat(row)
    }
  }

  private func statsTableExists(_ table: String, db: Connection) throws -> Bool {
    let rows = try db.prepareRowIterator(
      "SELECT 1 AS found FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      bindings: [table]
    )
    return try rows.failableNext() != nil
  }
}
