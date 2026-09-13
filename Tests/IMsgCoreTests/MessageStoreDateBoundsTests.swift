import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test(arguments: ["0001-01-01T00:00:00Z", "9999-01-01T00:00:00Z"])
func historyComparesDistantDateBoundsWithoutClipping(iso: String) throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  try db.execute(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, 'fixture', 'fixture', '', 'iMessage')"
  )
  for rowID in 1...3 {
    let timestamp: Int64 = rowID == 1 ? .min : rowID == 2 ? 0 : .max
    try db.run(
      "INSERT INTO message(ROWID, text, date, is_from_me) VALUES (?, 'fixture', ?, 0)", rowID,
      timestamp)
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", rowID)
  }
  let store = try MessageStore(connection: db, path: ":memory:")
  let start = try MessageFilter.fromISO(participants: [], startISO: iso, endISO: nil)
  let end = try MessageFilter.fromISO(participants: [], startISO: nil, endISO: iso)
  let distantPast = iso.hasPrefix("0001")
  #expect(try store.messages(chatID: 1, limit: 10, filter: start).count == (distantPast ? 3 : 0))
  #expect(try store.messages(chatID: 1, limit: 10, filter: end).count == (distantPast ? 0 : 3))
}

@Test
func epochQueryBoundsKeepNormalDatesAsIntegers() throws {
  let epoch = Date(timeIntervalSince1970: MessageStore.appleEpochOffset)
  #expect(try MessageStore.appleEpoch(epoch) as? Int64 == 0)
  #expect(try MessageStore.appleEpoch(epoch.addingTimeInterval(1)) as? Int64 == 1_000_000_000)
  #expect(try MessageStore.appleEpoch(epoch.addingTimeInterval(-1)) as? Int64 == -1_000_000_000)
}

@Test(arguments: [Double.infinity, -.infinity, .nan])
func epochQueryBoundsRejectNonfiniteDates(seconds: Double) throws {
  #expect(throws: IMsgError.self) {
    try MessageStore.appleEpoch(Date(timeIntervalSince1970: seconds))
  }
}
