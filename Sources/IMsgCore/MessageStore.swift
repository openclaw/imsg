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

  private struct URLBalloonDedupeEntry: Sendable {
    let rowID: Int64
    let date: Date
  }

  private static let urlBalloonDedupeWindow: TimeInterval = 90
  private static let urlBalloonDedupeRetention: TimeInterval = 10 * 60

  private var urlBalloonDedupe: [String: URLBalloonDedupeEntry] = [:]

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
      self.schema = MessageStoreSchema(connection: self.connection)
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
    self.schema = MessageStoreSchema(
      base: MessageStoreSchema(connection: connection),
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

  func shouldSkipURLBalloonDuplicate(
    chatID: Int64,
    sender: String,
    text: String,
    isFromMe: Bool,
    date: Date,
    rowID: Int64
  ) -> Bool {
    guard !text.isEmpty else { return false }

    pruneURLBalloonDedupe(referenceDate: date)

    let key = "\(chatID)|\(isFromMe ? 1 : 0)|\(sender)|\(text)"
    let current = URLBalloonDedupeEntry(rowID: rowID, date: date)
    guard let previous = urlBalloonDedupe[key] else {
      urlBalloonDedupe[key] = current
      return false
    }

    urlBalloonDedupe[key] = current
    if rowID <= previous.rowID {
      return true
    }
    return date.timeIntervalSince(previous.date) <= MessageStore.urlBalloonDedupeWindow
  }

  private func pruneURLBalloonDedupe(referenceDate: Date) {
    guard !urlBalloonDedupe.isEmpty else { return }
    let cutoff = referenceDate.addingTimeInterval(-MessageStore.urlBalloonDedupeRetention)
    urlBalloonDedupe = urlBalloonDedupe.filter { $0.value.date >= cutoff }
  }
}

extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
