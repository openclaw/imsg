import Foundation
import SQLite

public struct MessageStats: Sendable, Equatable, Codable {
  public let totalMessages: Int64
  public let chats: [ChatMessageStats]
  public let handles: [HandleMessageStats]
  public let services: [ServiceMessageStats]
  public let dates: [DateMessageStats]
  public let media: MediaStats?

  public init(
    totalMessages: Int64,
    chats: [ChatMessageStats],
    handles: [HandleMessageStats],
    services: [ServiceMessageStats],
    dates: [DateMessageStats],
    media: MediaStats? = nil
  ) {
    self.totalMessages = totalMessages
    self.chats = chats
    self.handles = handles
    self.services = services
    self.dates = dates
    self.media = media
  }

  enum CodingKeys: String, CodingKey {
    case totalMessages = "total_messages"
    case chats
    case handles
    case services
    case dates
    case media
  }
}

public struct ChatMessageStats: Sendable, Equatable, Codable {
  public let chatID: Int64
  public let identifier: String
  public let name: String
  public let service: String
  public let messageCount: Int64

  enum CodingKeys: String, CodingKey {
    case chatID = "chat_id"
    case identifier
    case name
    case service
    case messageCount = "message_count"
  }
}

public struct HandleMessageStats: Sendable, Equatable, Codable {
  public let handle: String
  public let messageCount: Int64

  enum CodingKeys: String, CodingKey {
    case handle
    case messageCount = "message_count"
  }
}

public struct ServiceMessageStats: Sendable, Equatable, Codable {
  public let service: String
  public let messageCount: Int64

  enum CodingKeys: String, CodingKey {
    case service
    case messageCount = "message_count"
  }
}

public struct DateMessageStats: Sendable, Equatable, Codable {
  public let date: String
  public let messageCount: Int64

  enum CodingKeys: String, CodingKey {
    case date
    case messageCount = "message_count"
  }
}

public struct MediaStats: Sendable, Equatable, Codable {
  public let totalAttachments: Int64
  public let totalBytes: Int64
  public let types: [MediaTypeStats]
  public let chats: [ChatMediaStats]

  public init(
    totalAttachments: Int64,
    totalBytes: Int64,
    types: [MediaTypeStats],
    chats: [ChatMediaStats]
  ) {
    self.totalAttachments = totalAttachments
    self.totalBytes = totalBytes
    self.types = types
    self.chats = chats
  }

  enum CodingKeys: String, CodingKey {
    case totalAttachments = "total_attachments"
    case totalBytes = "total_bytes"
    case types
    case chats
  }
}

public struct MediaTypeStats: Sendable, Equatable, Codable {
  public let uti: String
  public let mimeType: String
  public let attachmentCount: Int64
  public let totalBytes: Int64

  enum CodingKeys: String, CodingKey {
    case uti
    case mimeType = "mime_type"
    case attachmentCount = "attachment_count"
    case totalBytes = "total_bytes"
  }
}

public struct ChatMediaStats: Sendable, Equatable, Codable {
  public let chatID: Int64
  public let identifier: String
  public let name: String
  public let attachmentCount: Int64
  public let totalBytes: Int64

  enum CodingKeys: String, CodingKey {
    case chatID = "chat_id"
    case identifier
    case name
    case attachmentCount = "attachment_count"
    case totalBytes = "total_bytes"
  }
}

extension MessageStore {
  public func messageStats(chatID: Int64? = nil, includeMedia: Bool = false) throws -> MessageStats
  {
    try withConnection { db in
      let filter = MessageStatsFilter(chatID: chatID)
      let totalMessages = try messageStatsTotal(db: db, filter: filter)
      return MessageStats(
        totalMessages: totalMessages,
        chats: try messageStatsByChat(db: db, filter: filter),
        handles: try messageStatsByHandle(db: db, filter: filter),
        services: try messageStatsByService(db: db, filter: filter),
        dates: try messageStatsByDate(db: db, filter: filter),
        media: includeMedia ? try mediaStats(db: db, filter: filter) : nil
      )
    }
  }

  public func mediaStats(chatID: Int64? = nil) throws -> MediaStats {
    try withConnection { db in
      try mediaStats(db: db, filter: MessageStatsFilter(chatID: chatID))
    }
  }

  private func messageStatsTotal(db: Connection, filter: MessageStatsFilter) throws -> Int64 {
    let rows = try db.prepareRowIterator(
      """
      SELECT COUNT(DISTINCT m.ROWID) AS message_count
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      \(filter.whereClause)
      """,
      bindings: filter.bindings
    )
    return try rows.failableNext().flatMap { try int64Value($0, "message_count") } ?? 0
  }

  private func messageStatsByChat(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [ChatMessageStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT c.ROWID AS chat_id,
             IFNULL(c.chat_identifier, '') AS identifier,
             IFNULL(c.display_name, c.chat_identifier) AS name,
             IFNULL(c.service_name, '') AS service,
             COUNT(DISTINCT m.ROWID) AS message_count
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      \(filter.whereClause)
      GROUP BY c.ROWID
      ORDER BY message_count DESC, c.ROWID ASC
      """,
      bindings: filter.bindings
    )
    var results: [ChatMessageStats] = []
    while let row = try rows.failableNext() {
      results.append(
        ChatMessageStats(
          chatID: try int64Value(row, "chat_id") ?? 0,
          identifier: try stringValue(row, "identifier"),
          name: try stringValue(row, "name"),
          service: try stringValue(row, "service"),
          messageCount: try int64Value(row, "message_count") ?? 0
        ))
    }
    return results
  }

  private func messageStatsByHandle(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [HandleMessageStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT CASE WHEN m.is_from_me = 1 THEN 'me' ELSE IFNULL(h.id, '') END AS handle,
             COUNT(DISTINCT m.ROWID) AS message_count
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      \(filter.whereClause)
      GROUP BY handle
      ORDER BY message_count DESC, handle ASC
      """,
      bindings: filter.bindings
    )
    var results: [HandleMessageStats] = []
    while let row = try rows.failableNext() {
      results.append(
        HandleMessageStats(
          handle: try stringValue(row, "handle").nilIfEmpty ?? "unknown",
          messageCount: try int64Value(row, "message_count") ?? 0
        ))
    }
    return results
  }

  private func messageStatsByService(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [ServiceMessageStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT IFNULL(m.service, '') AS service,
             COUNT(DISTINCT m.ROWID) AS message_count
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      \(filter.whereClause)
      GROUP BY service
      ORDER BY message_count DESC, service ASC
      """,
      bindings: filter.bindings
    )
    var results: [ServiceMessageStats] = []
    while let row = try rows.failableNext() {
      results.append(
        ServiceMessageStats(
          service: try stringValue(row, "service").nilIfEmpty ?? "unknown",
          messageCount: try int64Value(row, "message_count") ?? 0
        ))
    }
    return results
  }

  private func messageStatsByDate(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [DateMessageStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT m.date AS message_date
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      \(filter.whereClause)
      """,
      bindings: filter.bindings
    )
    var counts: [String: Int64] = [:]
    while let row = try rows.failableNext() {
      let day = Self.statsDayFormatter.string(
        from: appleDate(from: try int64Value(row, "message_date")))
      counts[day, default: 0] += 1
    }
    return
      counts
      .map { DateMessageStats(date: $0.key, messageCount: $0.value) }
      .sorted { lhs, rhs in
        lhs.date == rhs.date ? lhs.messageCount > rhs.messageCount : lhs.date < rhs.date
      }
  }

  private func mediaStats(db: Connection, filter: MessageStatsFilter) throws -> MediaStats {
    let totals = try mediaTotals(db: db, filter: filter)
    return MediaStats(
      totalAttachments: totals.attachments,
      totalBytes: totals.bytes,
      types: try mediaStatsByType(db: db, filter: filter),
      chats: try mediaStatsByChat(db: db, filter: filter)
    )
  }

  private func mediaTotals(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> (attachments: Int64, bytes: Int64) {
    let rows = try db.prepareRowIterator(
      """
      SELECT COUNT(DISTINCT a.ROWID) AS attachment_count,
             IFNULL(SUM(IFNULL(a.total_bytes, 0)), 0) AS total_bytes
      FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      JOIN message m ON m.ROWID = maj.message_id
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      \(filter.whereClause)
      """,
      bindings: filter.bindings
    )
    guard let row = try rows.failableNext() else { return (0, 0) }
    return (
      try int64Value(row, "attachment_count") ?? 0,
      try int64Value(row, "total_bytes") ?? 0
    )
  }

  private func mediaStatsByType(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [MediaTypeStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT IFNULL(a.uti, '') AS uti,
             IFNULL(a.mime_type, '') AS mime_type,
             COUNT(DISTINCT a.ROWID) AS attachment_count,
             IFNULL(SUM(IFNULL(a.total_bytes, 0)), 0) AS total_bytes
      FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      JOIN message m ON m.ROWID = maj.message_id
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      \(filter.whereClause)
      GROUP BY uti, mime_type
      ORDER BY attachment_count DESC, total_bytes DESC, uti ASC, mime_type ASC
      """,
      bindings: filter.bindings
    )
    var results: [MediaTypeStats] = []
    while let row = try rows.failableNext() {
      results.append(
        MediaTypeStats(
          uti: try stringValue(row, "uti").nilIfEmpty ?? "unknown",
          mimeType: try stringValue(row, "mime_type").nilIfEmpty ?? "unknown",
          attachmentCount: try int64Value(row, "attachment_count") ?? 0,
          totalBytes: try int64Value(row, "total_bytes") ?? 0
        ))
    }
    return results
  }

  private func mediaStatsByChat(
    db: Connection,
    filter: MessageStatsFilter
  ) throws -> [ChatMediaStats] {
    let rows = try db.prepareRowIterator(
      """
      SELECT c.ROWID AS chat_id,
             IFNULL(c.chat_identifier, '') AS identifier,
             IFNULL(c.display_name, c.chat_identifier) AS name,
             COUNT(DISTINCT a.ROWID) AS attachment_count,
             IFNULL(SUM(IFNULL(a.total_bytes, 0)), 0) AS total_bytes
      FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      JOIN message m ON m.ROWID = maj.message_id
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      \(filter.whereClause)
      GROUP BY c.ROWID
      ORDER BY attachment_count DESC, total_bytes DESC, c.ROWID ASC
      """,
      bindings: filter.bindings
    )
    var results: [ChatMediaStats] = []
    while let row = try rows.failableNext() {
      results.append(
        ChatMediaStats(
          chatID: try int64Value(row, "chat_id") ?? 0,
          identifier: try stringValue(row, "identifier"),
          name: try stringValue(row, "name"),
          attachmentCount: try int64Value(row, "attachment_count") ?? 0,
          totalBytes: try int64Value(row, "total_bytes") ?? 0
        ))
    }
    return results
  }

  private static let statsDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

private struct MessageStatsFilter {
  let whereClause: String
  let bindings: [Binding?]

  init(chatID: Int64?) {
    if let chatID {
      self.whereClause = "WHERE cmj.chat_id = ?"
      self.bindings = [chatID]
    } else {
      self.whereClause = ""
      self.bindings = []
    }
  }
}
