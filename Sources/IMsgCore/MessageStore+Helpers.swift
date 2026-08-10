import Foundation
import SQLite

extension MessageStore {
  struct DecodedReaction: Sendable {
    let isReaction: Bool
    let reactionType: ReactionType?
    let isReactionAdd: Bool?
    let reactedToGUID: String?
  }

  static func tableColumns(connection: Connection, table: String) throws -> Set<String> {
    let rows = try connection.prepareRowIterator("PRAGMA table_info(\(table))")
    var columns = Set<String>()
    while let row = try rows.failableNext() {
      if let name = try row.get(Expression<String?>("name")) {
        columns.insert(name.lowercased())
      }
    }
    return columns
  }

  static func reactionColumnsPresent(in columns: Set<String>) -> Bool {
    return columns.contains("guid")
      && columns.contains("associated_message_guid")
      && columns.contains("associated_message_type")
  }

  static func detectReactionColumns(connection: Connection) -> Bool {
    let columns = (try? tableColumns(connection: connection, table: "message")) ?? []
    return reactionColumnsPresent(in: columns)
  }

  static func detectThreadOriginatorGUIDColumn(connection: Connection) -> Bool {
    return (try? tableColumns(connection: connection, table: "message"))?
      .contains("thread_originator_guid") == true
  }

  static func detectAttributedBody(connection: Connection) -> Bool {
    return (try? tableColumns(connection: connection, table: "message"))?
      .contains("attributedbody") == true
  }

  static func detectDestinationCallerID(connection: Connection) -> Bool {
    return (try? tableColumns(connection: connection, table: "message"))?
      .contains("destination_caller_id") == true
  }

  static func detectAudioMessageColumn(connection: Connection) -> Bool {
    return (try? tableColumns(connection: connection, table: "message"))?
      .contains("is_audio_message") == true
  }

  static func detectAttachmentUserInfo(connection: Connection) -> Bool {
    return (try? tableColumns(connection: connection, table: "attachment"))?
      .contains("user_info") == true
  }

  static func enhance(error: Error, path: String) -> Error {
    let message = String(describing: error).lowercased()
    if message.contains("out of memory (14)") || message.contains("authorization denied")
      || message.contains("unable to open database") || message.contains("cannot open")
    {
      return IMsgError.permissionDenied(path: path, underlying: error)
    }
    return error
  }

  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  func appleDate(from value: Int64?) -> Date {
    guard let value else { return Date(timeIntervalSince1970: MessageStore.appleEpochOffset) }
    return Date(
      timeIntervalSince1970: (Double(value) / 1_000_000_000) + MessageStore.appleEpochOffset)
  }

  func stringValue(_ binding: Binding?) -> String {
    return binding as? String ?? ""
  }

  func int64Value(_ binding: Binding?) -> Int64? {
    if let value = binding as? Int64 { return value }
    if let value = binding as? Int { return Int64(value) }
    if let value = binding as? Double { return Int64(value) }
    return nil
  }

  func intValue(_ binding: Binding?) -> Int? {
    if let value = binding as? Int { return value }
    if let value = binding as? Int64 { return Int(value) }
    if let value = binding as? Double { return Int(value) }
    return nil
  }

  func boolValue(_ binding: Binding?) -> Bool {
    if let value = binding as? Bool { return value }
    if let value = intValue(binding) { return value != 0 }
    return false
  }

  func dataValue(_ binding: Binding?) -> Data {
    if let blob = binding as? Blob {
      return Data(blob.bytes)
    }
    return Data()
  }

  func normalizeAssociatedGUID(_ guid: String) -> String {
    guard !guid.isEmpty else { return "" }
    guard let slash = guid.lastIndex(of: "/") else { return guid }
    let nextIndex = guid.index(after: slash)
    guard nextIndex < guid.endIndex else { return guid }
    return String(guid[nextIndex...])
  }

  func replyToGUID(associatedGuid: String, associatedType: Int?) -> String? {
    let normalized = normalizeAssociatedGUID(associatedGuid)
    guard !normalized.isEmpty else { return nil }
    if let type = associatedType, ReactionType.isReaction(type) {
      return nil
    }
    return normalized
  }

  func decodeReaction(
    associatedType: Int?,
    associatedGUID: String,
    text: String
  ) -> DecodedReaction {
    guard let typeValue = associatedType, ReactionType.isReaction(typeValue) else {
      return DecodedReaction(
        isReaction: false,
        reactionType: nil,
        isReactionAdd: nil,
        reactedToGUID: nil
      )
    }

    let isAdd = ReactionType.isReactionAdd(typeValue)
    let rawType = isAdd ? typeValue : typeValue - 1000
    let customEmoji = (rawType == 2006) ? extractCustomEmoji(from: text) : nil
    guard let reactionType = ReactionType(rawValue: rawType, customEmoji: customEmoji) else {
      return DecodedReaction(
        isReaction: true,
        reactionType: nil,
        isReactionAdd: isAdd,
        reactedToGUID: normalizeAssociatedGUID(associatedGUID)
      )
    }

    return DecodedReaction(
      isReaction: true,
      reactionType: reactionType,
      isReactionAdd: isAdd,
      reactedToGUID: normalizeAssociatedGUID(associatedGUID)
    )
  }
}
