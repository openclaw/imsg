import Foundation
import SQLite

public struct ScheduledMessage: Sendable, Equatable, Codable {
  public let rowID: Int64
  public let guid: String
  public let chatID: Int64
  public let chatIdentifier: String
  public let chatGUID: String
  public let chatName: String
  public let text: String
  public let service: String
  public let scheduledAt: Date
  public let scheduleType: Int
  public let scheduleState: Int

  public init(
    rowID: Int64,
    guid: String,
    chatID: Int64,
    chatIdentifier: String,
    chatGUID: String,
    chatName: String,
    text: String,
    service: String,
    scheduledAt: Date,
    scheduleType: Int,
    scheduleState: Int
  ) {
    self.rowID = rowID
    self.guid = guid
    self.chatID = chatID
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
    self.chatName = chatName
    self.text = text
    self.service = service
    self.scheduledAt = scheduledAt
    self.scheduleType = scheduleType
    self.scheduleState = scheduleState
  }
}

public enum ScheduledMessagesError: Error, CustomStringConvertible, Equatable, Sendable {
  case unsupportedSchema
  case invalidLimit

  public var description: String {
    switch self {
    case .unsupportedSchema:
      return
        "scheduled messages are unavailable because this Messages database has no schedule columns"
    case .invalidLimit:
      return "limit must be a positive integer"
    }
  }
}

extension MessageStore {
  public var supportsScheduledMessages: Bool {
    schema.hasScheduleTypeColumn || schema.hasScheduleStateColumn
  }

  public func scheduledMessages(limit: Int = 50, asOf: Date = Date()) throws
    -> [ScheduledMessage]
  {
    guard supportsScheduledMessages else { throw ScheduledMessagesError.unsupportedSchema }
    guard limit > 0 else { throw ScheduledMessagesError.invalidLimit }
    let scheduleTypeColumn = schema.hasScheduleTypeColumn ? "IFNULL(m.schedule_type, 0)" : "0"
    let scheduleStateColumn = schema.hasScheduleStateColumn ? "IFNULL(m.schedule_state, 0)" : "0"
    let bodyColumn = schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    let sql = """
      SELECT m.ROWID AS message_id,
             IFNULL(m.guid, '') AS guid,
             IFNULL(m.text, '') AS text,
             \(bodyColumn) AS body,
             IFNULL(m.service, '') AS service,
             IFNULL(m.date, 0) AS scheduled_date,
             \(scheduleTypeColumn) AS schedule_type,
             \(scheduleStateColumn) AS schedule_state,
             c.ROWID AS chat_id,
             IFNULL(c.chat_identifier, '') AS chat_identifier,
             IFNULL(c.guid, '') AS chat_guid,
             IFNULL(c.display_name, c.chat_identifier) AS chat_name
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      WHERE (\(scheduleTypeColumn) != 0 OR \(scheduleStateColumn) != 0)
        AND IFNULL(m.is_from_me, 0) = 1
        AND IFNULL(m.date, 0) >= ?
      ORDER BY m.date ASC, m.ROWID ASC
      LIMIT ?
      """
    return try withConnection { db in
      var results: [ScheduledMessage] = []
      let rows = try db.prepareRowIterator(
        sql,
        bindings: [MessageStore.appleEpoch(asOf), limit])
      while let row = try rows.failableNext() {
        let rawText = try stringValue(row, "text")
        let text =
          rawText.isEmpty
          ? TypedStreamParser.parseAttributedBody(try dataValue(row, "body")) : rawText
        results.append(
          ScheduledMessage(
            rowID: try int64Value(row, "message_id") ?? 0,
            guid: try stringValue(row, "guid"),
            chatID: try int64Value(row, "chat_id") ?? 0,
            chatIdentifier: try stringValue(row, "chat_identifier"),
            chatGUID: try stringValue(row, "chat_guid"),
            chatName: try stringValue(row, "chat_name"),
            text: text,
            service: try stringValue(row, "service"),
            scheduledAt: appleDate(from: try int64Value(row, "scheduled_date")),
            scheduleType: try intValue(row, "schedule_type") ?? 0,
            scheduleState: try intValue(row, "schedule_state") ?? 0
          ))
      }
      return results
    }
  }

}
