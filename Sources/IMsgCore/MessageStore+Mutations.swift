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

extension MessageMutationStamp {
  // Messages usually leaves date_retracted at 0 and records an unsend as retracted parts (rp).
  // Unsending only some of the original parts (otr) leaves the rest, so that stays an edit.
  init(dateEdited: Int64, dateRetracted: Int64, summaryInfo: Data) {
    edited = dateEdited
    if dateRetracted > 0 {
      retracted = dateRetracted
    } else if dateEdited > 0,
      let info = try? PropertyListSerialization.propertyList(
        from: summaryInfo, options: [], format: nil) as? [String: Any],
      let originalParts = info["otr"] as? [String: Any], !originalParts.isEmpty,
      let retractedParts = info["rp"] as? [Int],
      originalParts.keys.allSatisfy({ Int($0).map(retractedParts.contains) == true })
    {
      retracted = dateEdited
    } else {
      retracted = 0
    }
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
    let summaryInfo = schema.hasMessageSummaryInfoColumn ? "m.message_summary_info" : "NULL"
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
        SELECT m.ROWID, COALESCE(\(edited), 0), COALESCE(\(retracted), 0), \(summaryInfo)
        FROM message m WHERE (\(edited) > 0 OR \(retracted) > 0) \(scope)
        """, chatID.map { [$0 as Binding?] } ?? [])
      {
        guard let rowID = row[0] as? Int64 else { continue }
        stamps[rowID] = MessageMutationStamp(
          dateEdited: row[1] as? Int64 ?? 0, dateRetracted: row[2] as? Int64 ?? 0,
          summaryInfo: (row[3] as? Blob).map { Data($0.bytes) } ?? Data())
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
      return (message, try mutationStamp(row, columns: selection.columns))
    }
  }

  func mutationStamp(_ row: Row, columns: MessageRowColumns) throws -> MessageMutationStamp {
    MessageMutationStamp(
      dateEdited: try int64Value(row, columns.dateEdited) ?? 0,
      dateRetracted: try int64Value(row, columns.dateRetracted) ?? 0,
      summaryInfo: try dataValue(row, columns.messageSummaryInfo))
  }
}
