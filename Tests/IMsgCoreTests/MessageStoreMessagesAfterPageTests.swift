import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesAfterPageAdvancesPastCoalescedPhysicalRows() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let page = try store.messagesAfterPage(afterRowID: 0, chatID: 1, limit: 1)

  #expect(page.messages.map(\.rowID) == [1])
  #expect(page.messages.first?.urlPreview?.rowID == 2)
  #expect(page.nextRowID == 2)
  #expect(page.hasMore == false)
}

@Test
func messagesAfterPageCanAdvanceAnEmptySuppressedPage() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  let store = try MessageStore(connection: db, path: ":memory:")
  let previewPage = try store.messagesAfterPage(afterRowID: 1, chatID: 1, limit: 1)
  #expect(previewPage.messages.isEmpty)
  #expect(previewPage.nextRowID == 2)
  #expect(previewPage.hasMore == false)
}

@Test
func messagesAfterPageFillsPastSuppressedPreviewRows() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "after",
    guid: "after-guid",
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let page = try store.messagesAfterPage(afterRowID: 1, chatID: 1, limit: 1)

  #expect(page.messages.map(\.rowID) == [3])
  #expect(page.nextRowID == 3)
  #expect(page.hasMore == false)
}

@Test
func messagesAfterPageResolvesPreviewPastAnInterleavedChatRow() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    chatID: 1,
    text: "Dump https://example.com",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    chatID: 2,
    text: "other chat",
    guid: "other-guid",
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    chatID: 1,
    text: "https://example.com",
    guid: "preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let first = try store.messagesAfterPage(afterRowID: 0, chatID: nil, limit: 1)
  #expect(first.messages.map(\.rowID) == [1])
  #expect(first.messages.first?.urlPreview?.rowID == 3)
  #expect(first.nextRowID == 1)
  #expect(first.hasMore == true)

  let second = try store.messagesAfterPage(afterRowID: first.nextRowID, chatID: nil, limit: 1)
  #expect(second.messages.map(\.rowID) == [2])
  #expect(second.nextRowID == 3)
  #expect(second.hasMore == false)
}
