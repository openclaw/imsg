import Foundation
import SQLite

extension MessageStore {
  public func chatInfo(
    matchingExactTarget target: String,
    preferredServices: [String] = []
  ) throws -> ChatInfo? {
    try chatInfo(
      matchingExactTarget: target,
      predicate: "c.chat_identifier = ? OR c.guid = ?",
      preferredServices: preferredServices,
      bindingCount: 2
    )
  }

  public func chatInfo(
    matchingExactIdentifier identifier: String,
    preferredServices: [String] = []
  ) throws -> ChatInfo? {
    try chatInfo(
      matchingExactTarget: identifier,
      predicate: "c.chat_identifier = ?",
      preferredServices: preferredServices,
      bindingCount: 1
    )
  }

  public func chatInfo(matchingExactGUID guid: String) throws -> ChatInfo? {
    try chatInfo(
      matchingExactTarget: guid,
      predicate: "c.guid = ?",
      preferredServices: [],
      bindingCount: 1
    )
  }

  private func chatInfo(
    matchingExactTarget target: String,
    predicate: String,
    preferredServices: [String],
    bindingCount: Int
  ) throws -> ChatInfo? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let accountIDColumn = schema.hasChatAccountIDColumn ? "IFNULL(c.account_id, '')" : "''"
    let accountLoginColumn = schema.hasChatAccountLoginColumn ? "IFNULL(c.account_login, '')" : "''"
    let lastAddressedHandleColumn =
      schema.hasChatLastAddressedHandleColumn ? "IFNULL(c.last_addressed_handle, '')" : "''"
    let serviceOrder: String
    if preferredServices.isEmpty {
      serviceOrder = "ORDER BY c.ROWID DESC"
    } else {
      let placeholders = Array(repeating: "?", count: preferredServices.count).joined(
        separator: ",")
      serviceOrder =
        "ORDER BY CASE WHEN c.service_name IN (\(placeholders)) THEN 0 ELSE 1 END, c.ROWID DESC"
    }
    let sql = """
      SELECT c.ROWID AS chat_rowid, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             IFNULL(c.display_name, c.chat_identifier) AS name, IFNULL(c.service_name, '') AS service,
             \(accountIDColumn) AS account_id,
             \(accountLoginColumn) AS account_login,
             \(lastAddressedHandleColumn) AS last_addressed_handle
      FROM chat c
      WHERE \(predicate)
      \(serviceOrder)
      LIMIT 1
      """
    return try withConnection { db in
      let rows = try db.prepareRowIterator(
        sql,
        bindings: Array(repeating: trimmed, count: bindingCount) + preferredServices
      )
      guard let row = try rows.failableNext() else { return nil }
      return ChatInfo(
        id: try int64Value(row, "chat_rowid") ?? 0,
        identifier: try stringValue(row, "identifier"),
        guid: try stringValue(row, "guid"),
        name: try stringValue(row, "name"),
        service: try stringValue(row, "service"),
        accountID: try stringValue(row, "account_id").nilIfEmpty,
        accountLogin: try stringValue(row, "account_login").nilIfEmpty,
        lastAddressedHandle: try stringValue(row, "last_addressed_handle").nilIfEmpty
      )
    }
  }

  public func chatInfo(
    matchingTarget target: String,
    preferredServices: [String] = []
  ) throws -> ChatInfo? {
    let candidates = Self.chatTargetCandidates(target)
    guard !candidates.isEmpty else { return nil }

    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
    let accountIDColumn = schema.hasChatAccountIDColumn ? "IFNULL(c.account_id, '')" : "''"
    let accountLoginColumn = schema.hasChatAccountLoginColumn ? "IFNULL(c.account_login, '')" : "''"
    let lastAddressedHandleColumn =
      schema.hasChatLastAddressedHandleColumn ? "IFNULL(c.last_addressed_handle, '')" : "''"
    let serviceOrder: String
    if preferredServices.isEmpty {
      serviceOrder = ""
    } else {
      let servicePlaceholders = Array(repeating: "?", count: preferredServices.count)
        .joined(separator: ",")
      serviceOrder =
        "ORDER BY CASE WHEN c.service_name IN (\(servicePlaceholders)) THEN 0 ELSE 1 END, c.ROWID DESC"
    }
    let sql = """
      SELECT c.ROWID AS chat_rowid, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             IFNULL(c.display_name, c.chat_identifier) AS name, IFNULL(c.service_name, '') AS service,
             \(accountIDColumn) AS account_id,
             \(accountLoginColumn) AS account_login,
             \(lastAddressedHandleColumn) AS last_addressed_handle
      FROM chat c
      WHERE c.chat_identifier IN (\(placeholders))
         OR c.guid IN (\(placeholders))
      \(serviceOrder)
      LIMIT 1
      """
    let bindings: [Binding?] = candidates + candidates + preferredServices
    return try withConnection { db in
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      guard let row = try rows.failableNext() else { return nil }
      return ChatInfo(
        id: try int64Value(row, "chat_rowid") ?? 0,
        identifier: try stringValue(row, "identifier"),
        guid: try stringValue(row, "guid"),
        name: try stringValue(row, "name"),
        service: try stringValue(row, "service"),
        accountID: try stringValue(row, "account_id").nilIfEmpty,
        accountLogin: try stringValue(row, "account_login").nilIfEmpty,
        lastAddressedHandle: try stringValue(row, "last_addressed_handle").nilIfEmpty
      )
    }
  }

  public func latestUnjoinedSentMessageRowID(
    matchingTargetHandles handles: [String],
    since date: Date
  ) throws -> Int64? {
    let candidates = Self.chatTargetHandleCandidates(handles)
    guard !candidates.isEmpty else { return nil }

    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
    let sql = """
      SELECT m.ROWID AS message_rowid
      FROM message m
      LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 1
        AND m.date >= ?
        AND IFNULL(m.text, '') = ''
        AND cmj.message_id IS NULL
        AND IFNULL(h.id, '') IN (\(placeholders))
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT 1
      """
    let bindings: [Binding?] = [MessageStore.appleEpoch(date)] + candidates
    return try withConnection { db in
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      guard let row = try rows.failableNext() else { return nil }
      return try int64Value(row, "message_rowid")
    }
  }

  private static func chatTargetHandleCandidates(_ handles: [String]) -> [String] {
    var candidates: [String] = []
    for handle in handles {
      candidates.append(contentsOf: chatTargetCandidates(handle))
    }
    return dedupe(candidates)
  }

  private static func chatTargetCandidates(_ target: String) -> [String] {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var candidates = [trimmed]
    if let toggled = toggledAnyGroupPolarity(trimmed) {
      candidates.append(toggled)
    }
    if let bare = bareAnyGroupIdentifier(trimmed) {
      candidates.append(bare)
    }
    return dedupe(candidates)
  }

  private static func toggledAnyGroupPolarity(_ value: String) -> String? {
    if value.hasPrefix("any;+;") {
      return "any;-;" + value.dropFirst("any;+;".count)
    }
    if value.hasPrefix("any;-;") {
      return "any;+;" + value.dropFirst("any;-;".count)
    }
    return nil
  }

  private static func bareAnyGroupIdentifier(_ value: String) -> String? {
    if value.hasPrefix("any;+;") {
      return String(value.dropFirst("any;+;".count))
    }
    if value.hasPrefix("any;-;") {
      return String(value.dropFirst("any;-;".count))
    }
    return nil
  }

  private static func dedupe(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values where !value.isEmpty {
      if seen.insert(value).inserted {
        result.append(value)
      }
    }
    return result
  }
}
