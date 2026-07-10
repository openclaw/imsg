import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func chatBackgroundInfoDecodesPropertiesUsesDatabaseCacheAndOrdersEventsByDate() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  let messagesDirectory = root.appendingPathComponent("Library/Messages", isDirectory: true)
  try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
  let databaseURL = messagesDirectory.appendingPathComponent("chat.db")
  let db = try Connection(databaseURL.path)
  try createChatBackgroundSchema(db, includeOptionalColumns: true)

  let properties = try chatBackgroundPropertiesData(channelGUID: "channel-123")
  try db.run(
    "INSERT INTO chat(ROWID, guid, properties) VALUES (1, 'iMessage;+;chat123', ?)",
    Blob(bytes: [UInt8](properties))
  )
  let newerDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
  try db.run(
    """
    INSERT INTO message(ROWID, guid, item_type, group_action_type, date)
    VALUES
      (10, 'newer-clear', 3, 6, ?),
      (11, 'older-set', 3, 4, ?)
    """,
    MessageStore.appleEpoch(newerDate),
    MessageStore.appleEpoch(newerDate.addingTimeInterval(-3600))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 10), (1, 11)")

  let cacheRoot = messagesDirectory.appendingPathComponent(
    "TranscriptBackgroundCache",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
  try Data().write(to: cacheRoot.appendingPathComponent("channel-123"))
  try Data().write(to: cacheRoot.appendingPathComponent("channel-123-watchBackground"))

  let store = try MessageStore(path: databaseURL.path)
  let result = try store.chatBackgroundInfo(chatID: 1)
  let info = try #require(result)

  #expect(info.chatGUID == "iMessage;+;chat123")
  #expect(info.backgroundChannelGUID == "channel-123")
  #expect(info.assetURL == "file:///background")
  #expect(info.assetID == "asset-123")
  #expect(info.objectID == "object-123")
  #expect(info.fileSize == 4096)
  #expect(info.posterVersion == 2)
  #expect(info.communicationSafetyState == 1)
  #expect(info.version == 7)
  #expect(info.cachePath == cacheRoot.appendingPathComponent("channel-123").path)
  #expect(info.cacheExists)
  #expect(info.watchBackgroundExists)
  #expect(info.latestEvent?.rowID == 10)
  #expect(info.latestEvent?.action == "clear")
  #expect(info.latestEvent?.date == newerDate)
}

@Test
func chatBackgroundInfoHandlesMissingOptionalColumnsAndUnknownChat() throws {
  let db = try Connection(.inMemory)
  try createChatBackgroundSchema(db, includeOptionalColumns: false)
  try db.run("INSERT INTO chat(ROWID, guid) VALUES (1, 'iMessage;-;+123')")
  let store = try MessageStore(connection: db, path: ":memory:")

  let result = try store.chatBackgroundInfo(chatID: 1)
  let info = try #require(result)
  #expect(info.backgroundChannelGUID == nil)
  #expect(info.cachePath == nil)
  #expect(info.cacheExists == false)
  #expect(info.latestEvent == nil)
  #expect(try store.chatBackgroundInfo(chatID: 999) == nil)
}

private func createChatBackgroundSchema(
  _ db: Connection,
  includeOptionalColumns: Bool
) throws {
  let propertiesColumn = includeOptionalColumns ? ", properties BLOB" : ""
  let eventColumns =
    includeOptionalColumns ? ", guid TEXT, item_type INTEGER, group_action_type INTEGER" : ""
  try db.execute(
    """
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT\(propertiesColumn));
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER\(eventColumns));
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    """)
}

private func chatBackgroundPropertiesData(channelGUID: String) throws -> Data {
  let properties: [String: Any] = [
    "backgroundProperties": [
      "trabaid": channelGUID,
      "trabar": "file:///background",
      "trabas": "asset-123",
      "traboid": "object-123",
      "trabafs": 4096,
      "trabapv": 2,
      "trabaCommSafety": 1,
      "trabav": 7,
    ]
  ]
  return try PropertyListSerialization.data(
    fromPropertyList: properties,
    format: .binary,
    options: 0
  )
}
