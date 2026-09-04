import Foundation
import SQLite

public final class MessageStore: @unchecked Sendable {
  public static let appleEpochOffset: TimeInterval = 978_307_200

  public static var defaultPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return NSString(string: home).appendingPathComponent("Library/Messages/chat.db")
  }

  public let path: String

  private let connection: Connection
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  let schema: MessageStoreSchema

  public init(path: String = MessageStore.defaultPath) throws {
    let normalized = NSString(string: path).expandingTildeInPath
    self.path = normalized
    self.queue = DispatchQueue(label: "imsg.db", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    do {
      let uri = URL(fileURLWithPath: normalized).absoluteString
      let location = Connection.Location.uri(uri, parameters: [.mode(.readOnly)])
      self.connection = try Connection(location, readonly: true)
      self.connection.busyTimeout = 5
      try registerMessageSearch(in: self.connection)
      self.schema = try MessageStoreSchema(connection: self.connection)
    } catch {
      throw MessageStore.enhance(error: error, path: normalized)
    }
  }

  init(
    connection: Connection,
    path: String,
    hasAttributedBody: Bool? = nil,
    hasReactionColumns: Bool? = nil,
    hasThreadOriginatorGUIDColumn: Bool? = nil,
    hasThreadOriginatorPartColumn: Bool? = nil,
    hasDestinationCallerID: Bool? = nil,
    hasAudioMessageColumn: Bool? = nil,
    hasAttachmentUserInfo: Bool? = nil,
    hasBalloonBundleIDColumn: Bool? = nil,
    hasChatMessageJoinMessageDateColumn: Bool? = nil,
    hasChatAccountIDColumn: Bool? = nil,
    hasChatAccountLoginColumn: Bool? = nil,
    hasChatLastAddressedHandleColumn: Bool? = nil,
    hasIsReadColumn: Bool? = nil,
    hasDateReadColumn: Bool? = nil
  ) throws {
    self.path = path
    self.queue = DispatchQueue(label: "imsg.db.test", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    self.connection = connection
    self.connection.busyTimeout = 5
    try registerMessageSearch(in: self.connection)
    self.schema = MessageStoreSchema(
      base: try MessageStoreSchema(connection: connection),
      hasAttributedBody: hasAttributedBody,
      hasReactionColumns: hasReactionColumns,
      hasThreadOriginatorGUIDColumn: hasThreadOriginatorGUIDColumn,
      hasThreadOriginatorPartColumn: hasThreadOriginatorPartColumn,
      hasDestinationCallerID: hasDestinationCallerID,
      hasAudioMessageColumn: hasAudioMessageColumn,
      hasAttachmentUserInfo: hasAttachmentUserInfo,
      hasBalloonBundleIDColumn: hasBalloonBundleIDColumn,
      hasChatMessageJoinMessageDateColumn: hasChatMessageJoinMessageDateColumn,
      hasChatAccountIDColumn: hasChatAccountIDColumn,
      hasChatAccountLoginColumn: hasChatAccountLoginColumn,
      hasChatLastAddressedHandleColumn: hasChatLastAddressedHandleColumn,
      hasIsReadColumn: hasIsReadColumn,
      hasDateReadColumn: hasDateReadColumn
    )
  }

  func withConnection<T>(_ block: (Connection) throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try block(connection)
    }
    return try queue.sync {
      try block(connection)
    }
  }
}

struct URLBalloonDedupeState: Sendable {
  private struct Entry: Sendable {
    let rowID: Int64
    let date: Date
  }

  private static let duplicateWindow: TimeInterval = 90
  private static let retention: TimeInterval = 10 * 60

  private var entries: [String: Entry] = [:]

  mutating func shouldSkip(_ message: Message) -> Bool {
    guard !message.text.isEmpty else { return false }

    prune(referenceDate: message.date)

    let key =
      "\(message.chatID)|\(message.isFromMe ? 1 : 0)|\(message.sender)|\(message.text)"
    let current = Entry(rowID: message.rowID, date: message.date)
    guard let previous = entries[key] else {
      entries[key] = current
      return false
    }

    entries[key] = current
    if message.rowID <= previous.rowID {
      return true
    }
    return message.date.timeIntervalSince(previous.date) <= Self.duplicateWindow
  }

  private mutating func prune(referenceDate: Date) {
    guard !entries.isEmpty else { return }
    let cutoff = referenceDate.addingTimeInterval(-Self.retention)
    entries = entries.filter { $0.value.date >= cutoff }
  }
}

extension MessageStore {
  public var supportsReactions: Bool { schema.hasReactionColumns }

  public var supportsReplyContext: Bool {
    schema.hasReplyToGUIDColumn || schema.hasThreadOriginatorGUIDColumn
  }

  public var supportsRoutingMetadata: Bool {
    schema.hasDestinationCallerID || schema.hasChatAccountIDColumn
      || schema.hasChatAccountLoginColumn || schema.hasChatLastAddressedHandleColumn
  }

  public var supportsBalloonPayloads: Bool {
    schema.hasBalloonBundleIDColumn
      && (schema.hasPayloadDataColumn || schema.hasMessageSummaryInfoColumn)
  }
}

extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
