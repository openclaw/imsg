import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messageRowSelectionGatesPollPayloadBlobs() throws {
  let db = try Connection(.inMemory)
  var options = MessageDatabaseFixture.SchemaOptions()
  options.includeReactionColumns = true
  options.includeBalloonBundleID = true
  options.includePayloadData = true
  options.includeMessageSummaryInfo = true
  try MessageDatabaseFixture.createSchema(db, options: options)

  let store = try MessageStore(connection: db, path: ":memory:")
  let query = ChatMessagesQuery(
    store: store,
    chatID: ChatID(rawValue: 1),
    limit: 10,
    filter: nil
  )

  #expect(query.selection.selectList.contains("CASE WHEN"))
  #expect(query.selection.selectList.contains("m.associated_message_type = 4000"))
  #expect(query.selection.selectList.contains("m.payload_data ELSE NULL"))
  #expect(query.selection.selectList.contains("m.message_summary_info ELSE NULL"))
  #expect(!query.selection.selectList.contains("m.payload_data AS payload_data"))
  #expect(!query.selection.selectList.contains("m.message_summary_info AS message_summary_info"))
}

@Test
func pollSnapshotsSpanUpdatesAndKeepLatestEmptyVote() throws {
  let db = try Connection(.inMemory)
  var schema = MessageDatabaseFixture.SchemaOptions()
  schema.includeReactionColumns = true
  schema.includeBalloonBundleID = true
  schema.includePayloadData = true
  try MessageDatabaseFixture.createSchema(db, options: schema)
  let options: [String: Any] = [
    "orderedPollOptions": [
      ["optionIdentifier": "a", "pollOptionText": "A"],
      ["optionIdentifier": "b", "pollOptionText": "B"],
    ]
  ]
  let payload = Blob(bytes: [UInt8](try applePollEnvelopePayload(jsonObject: options)))
  for (rowID, guid, reference) in [
    (10, "update-a", "p/original"), (11, "update-b", "p:0/original"),
  ] {
    try db.run(
      """
      INSERT INTO message(ROWID, guid, associated_message_guid, associated_message_type, balloon_bundle_id, payload_data, date)
      VALUES (?, ?, ?, 2, ?, ?, 1)
      """,
      rowID, guid, reference, testPollBundleID, payload)
  }
  let store = try MessageStore(connection: db, path: ":memory:")
  func insertVote(_ rowID: Int, _ reference: String, _ selected: [String], mine: Bool = true) throws
  {
    let data = try applePollEnvelopePayload(jsonObject: [
      "votes": selected.map { ["voteOptionIdentifier": $0] }
    ])
    try db.run(
      """
      INSERT INTO message(ROWID, guid, associated_message_guid, associated_message_type, payload_data, date, is_from_me)
      VALUES (?, ?, ?, 4000, ?, ?, ?)
      """,
      rowID, "vote-\(rowID)", reference, Blob(bytes: [UInt8](data)), rowID, mine ? 1 : 0)
  }
  try insertVote(98, "p/unrelated", ["unrelated"])
  try insertVote(99, "p/update-a", ["inbound"], mine: false)
  for (rowID, reference, selected) in [
    (2, "original", ["a"]), (3, "p/update-a", ["a", "b"]),
    (4, "p:0/update-b", ["b"]), (5, "p/update-a", []),
  ] {
    try insertVote(rowID, reference, selected)
    for guid in ["original", "p:0/update-a", "update-b"] {
      #expect(try store.pollSelectedOptionIDs(guid: guid) == selected)
      #expect(try store.pollOptions(guid: guid).map(\.id) == ["a", "b"])
    }
  }
}
