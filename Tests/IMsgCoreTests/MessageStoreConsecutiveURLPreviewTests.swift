import Foundation
import Testing

@testable import IMsgCore

@Test
func messagesByChatCoalescesConsecutiveURLPreviews() throws {
  let db = try makeURLPreviewTestDB()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try insertURLPreviewTestMessage(
    db,
    rowID: 1,
    text: "See https://one.example and https://two.example",
    guid: "text-guid",
    date: now
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 2,
    text: "https://one.example",
    guid: "first-preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(1)
  )
  try insertURLPreviewTestMessage(
    db,
    rowID: 3,
    text: "https://two.example",
    guid: "second-preview-guid",
    balloonBundleID: MessageStore.urlPreviewBalloonBundleID,
    date: now.addingTimeInterval(2)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)

  #expect(messages.map(\.rowID) == [1])
  #expect(messages.first?.urlPreview?.rowID == 3)
}
