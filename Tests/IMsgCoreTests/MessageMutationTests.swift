import Foundation
import SQLite
import Testing

@testable import IMsgCore

private func mutationFixture() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db,
    options: .init(
      includeAttributedBody: true, includeReactionColumns: true,
      includeMutationDates: true))
  try db.run(
    "INSERT INTO chat(ROWID, chat_identifier, guid) VALUES (1, 'one', 'chat-one'), (2, 'two', 'chat-two')"
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+15551234567')")
  for rowID in 1...3 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service)
      VALUES (?, 1, 'original', ?, 1000000000, 0, 'iMessage')
      """, rowID, "message-\(rowID)")
    try db.run("INSERT INTO chat_message_join VALUES (?, ?)", rowID == 3 ? 2 : 1, rowID)
  }
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func historyUsesEditedAttributedBodyAndClearsUnsentContent() throws {
  let store = try mutationFixture()
  try store.withConnection { db in
    try db.run(
      "UPDATE message SET attributedBody = ?, date_edited = 2000000000 WHERE ROWID = 1",
      Blob(bytes: Array(archivedAttributedBody("corrected"))))
    try db.run("UPDATE message SET date_retracted = 3000000000 WHERE ROWID = 2")
  }
  let messages = try store.messages(chatID: 1, limit: 10)
  let edited = try #require(messages.first { $0.rowID == 1 })
  #expect(edited.text == "corrected")
  #expect(
    try store.searchMessages(query: "corrected", match: "exact", limit: 10).map(\.rowID) == [1])
  #expect(edited.editedAt == Date(timeIntervalSince1970: MessageStore.appleEpochOffset + 2))
  #expect(edited.unsentAt == nil)
  #expect(edited.mutationEvent == nil)
  let unsent = try #require(messages.first { $0.rowID == 2 })
  #expect(unsent.text.isEmpty)
  #expect(unsent.unsentAt == Date(timeIntervalSince1970: MessageStore.appleEpochOffset + 3))
  #expect(unsent.mutationEvent == nil)
}

@Test
func mutationMetadataIsOptionalOnOlderDatabases() throws {
  let store = try TestDatabase.makeStore()
  #expect(try store.mutationStamps(chatID: nil).isEmpty)
  for message in try store.messages(chatID: 1, limit: 10) {
    #expect(message.editedAt == nil)
    #expect(message.unsentAt == nil)
    #expect(message.mutationEvent == nil)
  }
}

@Test(.timeLimit(.minutes(1)))
func watcherReportsEditsAndUnsendsOnceWithoutAdvancingRowCursor() async throws {
  let store = try mutationFixture()
  // Pre-existing edits are a baseline, not fresh watch events.
  try store.withConnection { db in
    try db.run("UPDATE message SET date_edited = 9000000000 WHERE ROWID = 1")
  }
  let polls = WatcherPollController()
  defer { polls.releaseAll() }
  let stream = MessageWatcher(store: store, didPoll: polls.didPoll).stream(
    chatID: 1,
    configuration: .init(debounceInterval: 0, fallbackPollInterval: 0.01, batchLimit: 1))
  let collector = Task { () throws -> [Message] in
    var result: [Message] = []
    for try await message in stream {
      result.append(message)
      if result.count == 3 { break }
    }
    return result
  }
  defer { collector.cancel() }
  await polls.waitForPoll(1)
  let paused = polls.pauseNextPoll()
  await polls.waitUntilPaused(paused)
  try store.withConnection { db in
    // Old timestamps and equal stamps on different rows must not be skipped.
    try db.run("UPDATE message SET date_edited = 2000000000, text = 'edited' WHERE ROWID IN (1, 3)")
    try db.run("UPDATE message SET date_retracted = 2000000000 WHERE ROWID = 2")
  }
  polls.release(paused)
  await polls.waitForPoll(paused + 4)
  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service, date_edited)
      VALUES (4, 1, 'new current content', 'message-4', 4000000000, 0, 'iMessage', 5000000000)
      """)
    try db.run("INSERT INTO chat_message_join VALUES (1, 4)")
  }
  let result = try await collector.value
  #expect(result.map(\.rowID) == [1, 2, 4])
  #expect(result.map(\.mutationEvent) == [.edited, .unsent, nil])
  #expect(result[0].text == "edited")
  #expect(result[1].text.isEmpty)
  #expect(result[2].text == "new current content")
}

@Test
func mutationLookupPreservesSecondaryChatMembership() throws {
  let store = try mutationFixture()
  try store.withConnection { db in
    try db.run("INSERT INTO chat_message_join VALUES (2, 1)")
    try db.run("UPDATE message SET date_edited = 2000000000 WHERE ROWID = 1")
  }
  #expect(try store.mutationMessage(rowID: 1, chatID: 2)?.0.chatID == 2)
  #expect(try store.mutationStamps(chatID: 2)[1]?.edited == 2_000_000_000)
}

@Test(.timeLimit(.minutes(1)))
func mutationOverflowPreservesTheCreationResumeCursor() async throws {
  let store = try mutationFixture()
  let polls = WatcherPollController()
  defer { polls.releaseAll() }
  let baseline = polls.pauseNextPoll()
  let stream = MessageWatcher(store: store, didPoll: polls.didPoll).stream(
    chatID: 1,
    configuration: .init(debounceInterval: 0, fallbackPollInterval: 0.01, bufferLimit: 1))
  await polls.waitUntilPaused(baseline)
  try store.withConnection { db in
    try db.run("UPDATE message SET date_edited = 2000000000 WHERE ROWID IN (1, 2)")
  }
  polls.release(baseline)
  await polls.waitForPoll(baseline + 1)
  let result = await drainWatcher(stream)
  #expect(result.messages.map(\.rowID) == [1])
  let error = try #require(result.error as? MessageWatcherOverflowError)
  #expect(error.resumeAfterRowID == 3)
}

@Test(.timeLimit(.minutes(1)))
func mutationBatchesDoNotReplayNewlyInsertedEditedRows() async throws {
  let store = try mutationFixture()
  let polls = WatcherPollController()
  defer { polls.releaseAll() }
  let baseline = polls.pauseNextPoll()
  let stream = MessageWatcher(store: store, didPoll: polls.didPoll).stream(
    chatID: 1, configuration: .init(debounceInterval: 0, fallbackPollInterval: 0.01, batchLimit: 1))
  await polls.waitUntilPaused(baseline)
  let collector = Task { () throws -> [Message] in
    var result: [Message] = []
    for try await message in stream {
      result.append(message)
      if message.rowID == 5 { break }
    }
    return result
  }
  defer { collector.cancel() }
  try store.withConnection { db in
    try db.run("UPDATE message SET date_edited = 2000000000 WHERE ROWID IN (1, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service, date_edited)
      VALUES (4, 1, 'already edited', 'message-4', 4000000000, 0, 'iMessage', 5000000000)
      """)
    try db.run("INSERT INTO chat_message_join VALUES (1, 4)")
  }
  polls.release(baseline)
  await polls.waitForPoll(baseline + 6)
  try store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service)
      VALUES (5, 1, 'done', 'message-5', 6000000000, 0, 'iMessage')
      """)
    try db.run("INSERT INTO chat_message_join VALUES (1, 5)")
  }
  let result = try await collector.value
  #expect(result.map(\.rowID) == [1, 4, 2, 5])
  #expect(result.map(\.mutationEvent) == [.edited, nil, .edited, nil])
}

@Test
func messageMutationMetadataPreservesInitializerFunctionReferences() {
  let grouped = Message.init(
    rowID:chatID:sender:text:date:isFromMe:service:handleID:attachmentsCount:guid:routing:
    balloonBundleID:urlPreview:reaction:poll:isRead:dateRead:)
  let flat = Message.init(
    rowID:chatID:sender:text:date:isFromMe:service:handleID:attachmentsCount:guid:replyToGUID:
    threadOriginatorGUID:threadOriginatorPart:destinationCallerID:balloonBundleID:urlPreview:
    replyToText:replyToSender:isReaction:reactionType:isReactionAdd:reactedToGUID:poll:isRead:
    dateRead:)
  let date = Date(timeIntervalSince1970: 100)
  let message = grouped(
    1, 2, "sender", "body", date, false, "iMessage", nil, 0, "guid",
    Message.RoutingMetadata(
      replyToGUID: "parent", threadOriginatorGUID: "thread",
      threadOriginatorPart: "part", destinationCallerID: "dest",
      replyToText: "quoted", replyToSender: "other"),
    "balloon", nil, Message.ReactionMetadata(), nil, true, date)
  let flatMessage = flat(
    1, 2, "sender", "body", date, false, "iMessage", nil, 0, "guid", "parent", "thread",
    "part", "dest", "balloon", nil, "quoted", "other", false, nil, nil, nil, nil, true, date)
  #expect(message == flatMessage)
  #expect(message.replyToGUID == "parent")
  #expect(message.editedAt == nil)
  #expect(message.unsentAt == nil)
  #expect(message.mutationEvent == nil)
}

@Test
func historyDoesNotRestoreStaleTextWhenEditedBodyIsEmptyOrMalformed() throws {
  let store = try mutationFixture()
  try store.withConnection { db in
    try db.run(
      "UPDATE message SET attributedBody = ?, date_edited = 2000000000 WHERE ROWID = 1",
      Blob(bytes: Array(archivedAttributedBody(""))))
    try db.run(
      "UPDATE message SET attributedBody = ?, date_edited = 2000000000 WHERE ROWID = 2",
      Blob(bytes: [0, 1, 2]))
    try db.run("UPDATE message SET attributedBody = ? WHERE ROWID = 3", Blob(bytes: [0, 1, 2]))
  }
  let edited = try store.messages(chatID: 1, limit: 10)
  #expect(edited.count == 2)
  #expect(edited.allSatisfy { $0.text.isEmpty && $0.editedAt != nil && $0.unsentAt == nil })
  #expect(try store.messages(chatID: 2, limit: 10).first?.text == "original")
}
