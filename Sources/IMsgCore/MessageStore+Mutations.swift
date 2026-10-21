import Foundation
import SQLite

struct MessageDatabaseVersion: Equatable {
  let externalChanges: Int64
  let localChanges: Int64
}

struct MessageMutationStamp: Equatable {
  let edited: Int64
  let retracted: Int64

  func event(since previous: Self?) -> Message.MutationEvent? {
    if retracted > 0 {
      return retracted != previous?.retracted ? .unsent : nil
    }
    return edited > 0 && edited != previous?.edited ? .edited : nil
  }
}

extension MessageStore {
  func mutationDatabaseVersion() throws -> MessageDatabaseVersion {
    try withConnection { db in
      MessageDatabaseVersion(
        externalChanges: try db.scalar("PRAGMA data_version") as? Int64 ?? 0,
        localChanges: try db.scalar("SELECT total_changes()") as? Int64 ?? 0)
    }
  }

  // Compare exact database stamps, rather than wall time: delayed iCloud updates
  // can carry old timestamps, and several rows can share the same timestamp.
  func mutationStamps(chatID: Int64?) throws -> [Int64: MessageMutationStamp] {
    guard schema.hasDateEditedColumn || schema.hasDateRetractedColumn else { return [:] }
    let edited = schema.hasDateEditedColumn ? "m.date_edited" : "0"
    let retracted = schema.hasDateRetractedColumn ? "m.date_retracted" : "0"
    let scope =
      chatID == nil
      ? ""
      : """
      AND EXISTS (SELECT 1 FROM chat_message_join
                  WHERE message_id = m.ROWID AND chat_id = ?)
      """
    return try withConnection { db in
      var stamps: [Int64: MessageMutationStamp] = [:]
      for row in try db.prepare(
        """
        SELECT m.ROWID, COALESCE(\(edited), 0), COALESCE(\(retracted), 0)
        FROM message m WHERE (\(edited) > 0 OR \(retracted) > 0) \(scope)
        """, chatID.map { [$0 as Binding?] } ?? [])
      {
        guard let rowID = row[0] as? Int64 else { continue }
        stamps[rowID] = MessageMutationStamp(
          edited: row[1] as? Int64 ?? 0, retracted: row[2] as? Int64 ?? 0)
      }
      return stamps
    }
  }

  func mutationMessage(rowID: Int64, chatID: Int64?) throws -> (Message, MessageMutationStamp)? {
    let selection = MessageRowSelection(
      store: self, chatIDColumn: chatID.map { String($0) } ?? MessageRowSelection.canonicalChatID)
    return try withConnection { db in
      let rows = try db.prepareRowIterator(
        """
        SELECT \(selection.selectList) FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID WHERE m.ROWID = ?
        """, bindings: [rowID])
      guard let row = try rows.failableNext() else { return nil }
      let decoded = try decodeMessageRow(row, columns: selection.columns, fallbackChatID: nil)
      var parents: ReplyParentCache = [:]
      var polls = PollOptionTextCache()
      let message = try message(from: decoded, db, parentCache: &parents, pollOptionCache: &polls)
      return (
        message,
        MessageMutationStamp(
          edited: try int64Value(row, selection.columns.dateEdited) ?? 0,
          retracted: try int64Value(row, selection.columns.dateRetracted) ?? 0)
      )
    }
  }
}
