import Foundation
import Testing

@testable import IMsgCore

@Test
func messageQueriesKeepOnePhysicalRowAcrossChatMemberships() throws {
  let db = try makeURLPreviewTestDB()
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db, rowID: 1, text: "See https://example.com", guid: "base", date: date, isFromMe: true)
  try insertURLPreviewTestMessage(
    db, rowID: 2, text: "https://example.com", guid: "preview",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: date.addingTimeInterval(1), isFromMe: true)
  try insertURLPreviewTestMessage(
    db, rowID: 3, text: "after", guid: "after", date: date.addingTimeInterval(2), isFromMe: true)
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 1), (2, 2)")
  let store = try MessageStore(connection: db, path: ":memory:")

  let forward = try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(forward.map(\.rowID) == [1, 3])
  // Stop before page enrichment on broken code, where duplicate row IDs trap in Dictionary.
  try #require(Set(forward.map(\.rowID)).count == forward.count)
  #expect(forward.map(\.chatID) == [1, 1])
  #expect(
    try store.searchMessages(query: "example.com", match: "contains", limit: 2).map(\.rowID) == [1])
  #expect(
    try store.latestSentMessage(matchingText: "See https://example.com", chatID: nil, since: date)?
      .chatID == 1)

  for limit in [1, 2] {
    var cursor: Int64 = 0
    var received: [Int64] = []
    for _ in 0..<4 {
      let page = try store.messagesAfterPage(afterRowID: cursor, chatID: nil, limit: limit)
      received.append(contentsOf: page.messages.map(\.rowID))
      if let first = page.messages.first, first.rowID == 1 {
        #expect(first.urlPreview?.rowID == 2)
      }
      if !page.hasMore { break }
      try #require(page.nextRowID > cursor)
      cursor = page.nextRowID
    }
    #expect(received == [1, 3])
  }
  let scoped = try store.messagesAfterPage(afterRowID: 0, chatID: 2, limit: 1)
  #expect(scoped.messages.map(\.rowID) == [1])
  #expect(scoped.messages.first?.chatID == 2)
  #expect(scoped.messages.first?.urlPreview?.rowID == 2)
}

@Test
func historyOrdersEqualDatesBeforeApplyingLimit() throws {
  let db = try makeURLPreviewTestDB()
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  for rowID: Int64 in 1...3 {
    try insertURLPreviewTestMessage(
      db, rowID: rowID, text: "message", guid: "m-\(rowID)", date: date)
  }
  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.messages(chatID: 1, limit: 1).map(\.rowID) == [3])
  #expect(try store.messages(chatID: 1, limit: 2).map(\.rowID) == [3, 2])
}

@Test
func readQueriesKeepNonReactionAssociatedEventsAsPreviewBoundaries() throws {
  let db = try makeURLPreviewTestDB()
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db, rowID: 1, text: "See https://example.com", guid: "base", date: date)
  try insertURLPreviewTestMessage(
    db, rowID: 2, text: "gap event", guid: "gap", associatedMessageType: 2500,
    date: date.addingTimeInterval(1))
  try insertURLPreviewTestMessage(
    db, rowID: 3, text: "https://example.com", guid: "preview",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID, date: date.addingTimeInterval(2))
  for (offset, type) in [2000, 2006, 3000, 3006].enumerated() {
    let rowID = Int64(offset + 4)
    try insertURLPreviewTestMessage(
      db, rowID: rowID, text: "Reacted 🎉 to message", guid: "reaction-\(rowID)",
      associatedMessageGUID: "p:0/base", associatedMessageType: type,
      date: date.addingTimeInterval(Double(rowID)))
  }
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 4)")
  let store = try MessageStore(connection: db, path: ":memory:")
  #expect(try store.messages(chatID: 1, limit: 10).map(\.rowID) == [3, 2, 1])
  #expect(try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10).map(\.rowID) == [1, 2, 3])
  #expect(
    try store.searchMessages(query: "gap event", match: "exact", limit: 1).map(\.rowID) == [2])
  let page = try store.messagesAfterPage(afterRowID: 0, chatID: nil, limit: 1)
  #expect(page.messages.map(\.rowID) == [1])
  #expect(page.messages.first?.urlPreview == nil)
  #expect(try store.reactionEventsAfter(afterRowID: 1, chatID: nil, limit: 1).map(\.rowID) == [4])
  #expect(
    try store.reactionEventsAfter(afterRowID: 1, chatID: nil, limit: 10).map(\.rowID) == [
      4, 5, 6, 7,
    ])
  #expect(try store.reactionEventsAfter(afterRowID: 1, chatID: 2, limit: 1).first?.chatID == 2)
}
