import Foundation

public struct MessageStats: Sendable, Equatable, Codable {
  public let totalMessages: Int64
  public let sentMessages: Int64
  public let receivedMessages: Int64
  public let timeZone: String
  public let chats: [ChatMessageStats]
  public let senders: [SenderMessageStats]
  public let services: [ServiceMessageStats]
  public let dates: [DateMessageStats]
  public let media: MediaStats?

  public init(
    totalMessages: Int64,
    sentMessages: Int64,
    receivedMessages: Int64,
    timeZone: String,
    chats: [ChatMessageStats],
    senders: [SenderMessageStats],
    services: [ServiceMessageStats],
    dates: [DateMessageStats],
    media: MediaStats? = nil
  ) {
    self.totalMessages = totalMessages
    self.sentMessages = sentMessages
    self.receivedMessages = receivedMessages
    self.timeZone = timeZone
    self.chats = chats
    self.senders = senders
    self.services = services
    self.dates = dates
    self.media = media
  }

  enum CodingKeys: String, CodingKey {
    case totalMessages = "total_messages"
    case sentMessages = "sent_messages"
    case receivedMessages = "received_messages"
    case timeZone = "time_zone"
    case chats
    case senders
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

public struct SenderMessageStats: Sendable, Equatable, Codable {
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

public enum MessageStatsError: LocalizedError, CustomStringConvertible, Sendable, Equatable {
  case invalidChatID(Int64)
  case chatNotFound(Int64)
  case invalidTimeZone(String)
  case mediaUnavailable

  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .invalidChatID(let chatID):
      return "chat_id must be a positive rowid (received \(chatID))"
    case .chatNotFound(let chatID):
      return "chat_id \(chatID) does not exist"
    case .invalidTimeZone(let identifier):
      return "invalid IANA time zone: \(identifier)"
    case .mediaUnavailable:
      return "media statistics are unavailable because attachment tables are missing"
    }
  }
}
