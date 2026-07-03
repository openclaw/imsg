import Foundation
import SQLite

private struct ChatRoutingSelection {
  let accountIDColumn: String
  let accountLoginColumn: String
  let lastAddressedHandleColumn: String

  init(schema: MessageStoreSchema) {
    self.accountIDColumn = schema.hasChatAccountIDColumn ? "IFNULL(c.account_id, '')" : "''"
    self.accountLoginColumn =
      schema.hasChatAccountLoginColumn ? "IFNULL(c.account_login, '')" : "''"
    self.lastAddressedHandleColumn =
      schema.hasChatLastAddressedHandleColumn ? "IFNULL(c.last_addressed_handle, '')" : "''"
  }
}

private struct ListChatsQuery {
  let sql: String
  let bindings: [Binding?]

  init(limit: Int, unreadOnly: Bool, schema: MessageStoreSchema) {
    let routing = ChatRoutingSelection(schema: schema)
    let unreadCountColumn = Self.unreadCountColumn(schema: schema)
    let havingClause = unreadOnly ? "HAVING unread_count > 0" : ""
    if schema.hasChatMessageJoinMessageDateColumn {
      self.sql = """
        SELECT c.ROWID AS chat_rowid, IFNULL(c.display_name, c.chat_identifier) AS name,
               c.chat_identifier AS chat_identifier, c.service_name AS service_name,
               MAX(cmj.message_date) AS last_date,
               \(routing.accountIDColumn) AS account_id,
               \(routing.accountLoginColumn) AS account_login,
               \(routing.lastAddressedHandleColumn) AS last_addressed_handle,
               \(unreadCountColumn)
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        GROUP BY c.ROWID
        \(havingClause)
        ORDER BY last_date DESC
        LIMIT ?
        """
    } else {
      self.sql = """
        SELECT c.ROWID AS chat_rowid, IFNULL(c.display_name, c.chat_identifier) AS name,
               c.chat_identifier AS chat_identifier, c.service_name AS service_name,
               MAX(m.date) AS last_date,
               \(routing.accountIDColumn) AS account_id,
               \(routing.accountLoginColumn) AS account_login,
               \(routing.lastAddressedHandleColumn) AS last_addressed_handle,
               \(unreadCountColumn)
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON m.ROWID = cmj.message_id
        GROUP BY c.ROWID
        \(havingClause)
        ORDER BY last_date DESC
        LIMIT ?
        """
    }
    self.bindings = [limit]
  }

  private static func unreadCountColumn(schema: MessageStoreSchema) -> String {
    guard schema.hasIsReadColumn else {
      return "0 AS unread_count"
    }
    return """
      (SELECT COUNT(*) FROM chat_message_join cmj_unread
       JOIN message m_unread ON m_unread.ROWID = cmj_unread.message_id
       WHERE cmj_unread.chat_id = c.ROWID
         AND m_unread.is_from_me = 0
         AND m_unread.is_read = 0) AS unread_count
      """
  }
}

private struct ChatInfoQuery {
  let sql: String
  let bindings: [Binding?]

  init(chatID: ChatID, schema: MessageStoreSchema) {
    let routing = ChatRoutingSelection(schema: schema)
    self.sql = """
      SELECT c.ROWID AS chat_rowid, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             IFNULL(c.display_name, c.chat_identifier) AS name, IFNULL(c.service_name, '') AS service,
             \(routing.accountIDColumn) AS account_id,
             \(routing.accountLoginColumn) AS account_login,
             \(routing.lastAddressedHandleColumn) AS last_addressed_handle
      FROM chat c
      WHERE c.ROWID = ?
      LIMIT 1
      """
    self.bindings = [chatID.rawValue]
  }
}

private struct ParticipantsQuery {
  let sql = """
    SELECT h.id
    FROM chat_handle_join chj
    JOIN handle h ON h.ROWID = chj.handle_id
    WHERE chj.chat_id = ?
    ORDER BY h.id ASC
    """
  let bindings: [Binding?]

  init(chatID: ChatID) {
    self.bindings = [chatID.rawValue]
  }
}

extension MessageStore {
  public func listChats(limit: Int, unreadOnly: Bool = false) throws -> [Chat] {
    let query = ListChatsQuery(limit: limit, unreadOnly: unreadOnly, schema: schema)
    return try withConnection { db in
      var chats: [Chat] = []
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        chats.append(
          Chat(
            id: try int64Value(row, "chat_rowid") ?? 0,
            identifier: try stringValue(row, "chat_identifier"),
            name: try stringValue(row, "name"),
            service: try stringValue(row, "service_name"),
            lastMessageAt: try appleDate(from: int64Value(row, "last_date")),
            accountID: try stringValue(row, "account_id").nilIfEmpty,
            accountLogin: try stringValue(row, "account_login").nilIfEmpty,
            lastAddressedHandle: try stringValue(row, "last_addressed_handle").nilIfEmpty,
            unreadCount: Int(try int64Value(row, "unread_count") ?? 0)
          ))
      }
      return chats
    }
  }

  public func chatInfo(chatID: Int64) throws -> ChatInfo? {
    let query = ChatInfoQuery(chatID: ChatID(rawValue: chatID), schema: schema)
    return try withConnection { db in
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
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
      return nil
    }
  }

  public func participants(chatID: Int64) throws -> [String] {
    let query = ParticipantsQuery(chatID: ChatID(rawValue: chatID))
    return try withConnection { db in
      var results: [String] = []
      var seen = Set<String>()
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let handle = try stringValue(row, "id")
        if handle.isEmpty { continue }
        if seen.insert(handle).inserted {
          results.append(handle)
        }
      }
      return results
    }
  }
}
