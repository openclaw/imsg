import Foundation
import SQLite

public struct ChatBackgroundInfo: Sendable, Equatable {
  public let chatID: Int64
  public let chatGUID: String
  public let backgroundChannelGUID: String?
  public let assetURL: String?
  public let assetID: String?
  public let objectID: String?
  public let fileSize: Int64?
  public let posterVersion: Int64?
  public let communicationSafetyState: Int64?
  public let version: Int64?
  public let cachePath: String?
  public let cacheExists: Bool
  public let watchBackgroundPath: String?
  public let watchBackgroundExists: Bool
  public let latestEvent: ChatBackgroundEvent?
}

public struct ChatBackgroundEvent: Sendable, Equatable {
  public let rowID: Int64
  public let guid: String
  public let action: String
  public let date: Date
}

extension MessageStore {
  public func chatBackgroundInfo(chatID: Int64) throws -> ChatBackgroundInfo? {
    let chatColumns = chatBackgroundColumns(table: "chat")
    let messageColumns = chatBackgroundColumns(table: "message")
    let propertiesColumn = chatColumns.contains("properties") ? "c.properties" : "NULL"
    let sql = """
      SELECT c.ROWID AS chat_rowid, IFNULL(c.guid, '') AS guid, \(propertiesColumn) AS properties
      FROM chat c
      WHERE c.ROWID = ?
      LIMIT 1
      """
    return try withConnection { db in
      let rows = try db.prepareRowIterator(sql, bindings: [chatID])
      guard let row = try rows.failableNext() else { return nil }
      let properties = decodeChatProperties(try dataValue(row, "properties"))
      let background = properties["backgroundProperties"] as? [String: Any] ?? [:]
      let channelGUID = stringProperty(background["trabaid"])
      let paths = transcriptBackgroundCachePaths(channelGUID: channelGUID)
      return ChatBackgroundInfo(
        chatID: try int64Value(row, "chat_rowid") ?? chatID,
        chatGUID: try stringValue(row, "guid"),
        backgroundChannelGUID: channelGUID,
        assetURL: stringProperty(background["trabar"]),
        assetID: stringProperty(background["trabas"]),
        objectID: stringProperty(background["traboid"]),
        fileSize: int64Property(background["trabafs"]),
        posterVersion: int64Property(background["trabapv"]),
        communicationSafetyState: int64Property(background["trabaCommSafety"]),
        version: int64Property(background["trabav"]),
        cachePath: paths.cache,
        cacheExists: paths.cache.map { FileManager.default.fileExists(atPath: $0) } ?? false,
        watchBackgroundPath: paths.watch,
        watchBackgroundExists: paths.watch.map {
          FileManager.default.fileExists(atPath: $0)
        } ?? false,
        latestEvent: try latestChatBackgroundEvent(
          db: db,
          chatID: chatID,
          messageColumns: messageColumns
        )
      )
    }
  }

  private func chatBackgroundColumns(table: String) -> Set<String> {
    (try? withConnection { db in
      MessageStore.tableColumns(connection: db, table: table)
    }) ?? []
  }

  private func decodeChatProperties(_ data: Data) -> [String: Any] {
    guard !data.isEmpty else { return [:] }
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    else { return [:] }
    return plist
  }

  private func transcriptBackgroundCachePaths(
    channelGUID: String?
  ) -> (cache: String?, watch: String?) {
    guard let channelGUID, !channelGUID.isEmpty, path != ":memory:" else {
      return (nil, nil)
    }
    let root =
      URL(fileURLWithPath: path)
      .deletingLastPathComponent()
      .appendingPathComponent("TranscriptBackgroundCache", isDirectory: true)
    return (
      root.appendingPathComponent(channelGUID).path,
      root.appendingPathComponent("\(channelGUID)-watchBackground").path
    )
  }

  private func latestChatBackgroundEvent(
    db: Connection,
    chatID: Int64,
    messageColumns: Set<String>
  ) throws -> ChatBackgroundEvent? {
    guard messageColumns.contains("guid"),
      messageColumns.contains("item_type"),
      messageColumns.contains("group_action_type"),
      messageColumns.contains("date")
    else { return nil }
    let sql = """
      SELECT m.ROWID AS message_rowid, IFNULL(m.guid, '') AS guid,
             m.group_action_type AS group_action_type, IFNULL(m.date, 0) AS date
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id = ?
        AND m.item_type = 3
        AND m.group_action_type IN (4, 6)
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT 1
      """
    let rows = try db.prepareRowIterator(sql, bindings: [chatID])
    guard let row = try rows.failableNext() else { return nil }
    let actionValue = try int64Value(row, "group_action_type")
    return ChatBackgroundEvent(
      rowID: try int64Value(row, "message_rowid") ?? 0,
      guid: try stringValue(row, "guid"),
      action: actionValue == 6 ? "clear" : "set",
      date: appleDate(from: try int64Value(row, "date"))
    )
  }

  private func stringProperty(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    return nil
  }

  private func int64Property(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? Double { return Int64(value) }
    return nil
  }
}
