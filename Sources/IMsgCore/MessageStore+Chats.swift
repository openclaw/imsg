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

  init(limit: Int, offset: Int = 0, unreadOnly: Bool, schema: MessageStoreSchema) {
    let routing = ChatRoutingSelection(schema: schema)
    let unreadSelection = UnreadChatSelection(enabled: unreadOnly)
    if schema.hasChatMessageJoinMessageDateColumn {
      self.sql = """
        SELECT c.ROWID AS chat_rowid, IFNULL(c.display_name, c.chat_identifier) AS name,
               c.chat_identifier AS chat_identifier, c.service_name AS service_name,
               MAX(cmj.message_date) AS last_date,
               \(routing.accountIDColumn) AS account_id,
               \(routing.accountLoginColumn) AS account_login,
               \(routing.lastAddressedHandleColumn) AS last_addressed_handle
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        \(unreadSelection.joinClause)
        GROUP BY c.ROWID
        ORDER BY last_date DESC, c.ROWID DESC
        LIMIT ? OFFSET ?
        """
    } else {
      self.sql = """
        SELECT c.ROWID AS chat_rowid, IFNULL(c.display_name, c.chat_identifier) AS name,
               c.chat_identifier AS chat_identifier, c.service_name AS service_name,
               MAX(m.date) AS last_date,
               \(routing.accountIDColumn) AS account_id,
               \(routing.accountLoginColumn) AS account_login,
               \(routing.lastAddressedHandleColumn) AS last_addressed_handle
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON m.ROWID = cmj.message_id
        \(unreadSelection.joinClause)
        GROUP BY c.ROWID
        ORDER BY last_date DESC, c.ROWID DESC
        LIMIT ? OFFSET ?
        """
    }
    self.bindings = [limit, offset]
  }
}

private struct UnreadChatSelection {
  let joinClause: String

  init(enabled: Bool) {
    guard enabled else {
      self.joinClause = ""
      return
    }
    self.joinClause = """
      JOIN (
        SELECT DISTINCT cmj_unread.chat_id
        FROM chat_message_join cmj_unread
        JOIN message m_unread ON m_unread.ROWID = cmj_unread.message_id
        WHERE m_unread.is_from_me = 0 AND m_unread.is_read = 0
      ) unread ON unread.chat_id = c.ROWID
      """
  }
}

private struct UnreadMessagesQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection

  init(store: MessageStore, chatIDs: [Int64]) {
    let selection = MessageRowSelection(store: store, includeChatID: true)
    self.selection = selection
    let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ", ")
    self.sql = """
      SELECT \(selection.selectList)
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id IN (\(placeholders))
        AND m.is_from_me = 0
        AND m.is_read = 0
      ORDER BY cmj.chat_id, m.ROWID
      """
    self.bindings = chatIDs.map { $0 as Binding? }
  }
}

private struct ChatRow {
  let id: Int64
  let identifier: String
  let name: String
  let service: String
  let lastMessageAt: Date
  let accountID: String?
  let accountLogin: String?
  let lastAddressedHandle: String?
}

private struct UnreadStateUnavailableError: LocalizedError, CustomStringConvertible {
  private let message =
    "Unread filtering is unavailable because this Messages database has no message.is_read column"

  var errorDescription: String? { message }
  var description: String { message }
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
  public var supportsUnreadState: Bool { schema.hasIsReadColumn }

  public func listChats(limit: Int, unreadOnly: Bool = false) throws -> [Chat] {
    guard limit > 0 else { return [] }
    if unreadOnly && !supportsUnreadState {
      throw UnreadStateUnavailableError()
    }
    return try withConnection { db in
      if !unreadOnly {
        let query = ListChatsQuery(limit: limit, unreadOnly: false, schema: schema)
        let rows = try chatRows(for: query, db: db)
        let counts = try unreadCounts(for: rows.map(\.id), db: db)
        return rows.map { chat(from: $0, unreadCount: counts[$0.id]) }
      }

      // The SQL predicate narrows the candidate set cheaply, then logical-message counting
      // rejects false positives such as unread URL-preview rows attached to read text rows.
      let batchLimit = max(limit, 50)
      var offset = 0
      var result: [Chat] = []
      while result.count < limit {
        let query = ListChatsQuery(
          limit: batchLimit,
          offset: offset,
          unreadOnly: true,
          schema: schema
        )
        let rows = try chatRows(for: query, db: db)
        guard !rows.isEmpty else { break }
        let counts = try unreadCounts(for: rows.map(\.id), db: db)
        for row in rows {
          guard let count = counts[row.id], count > 0 else { continue }
          result.append(chat(from: row, unreadCount: count))
          if result.count == limit { break }
        }
        guard rows.count == batchLimit else { break }
        offset += rows.count
      }
      return result
    }
  }

  private func chatRows(for query: ListChatsQuery, db: Connection) throws -> [ChatRow] {
    var result: [ChatRow] = []
    let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
    while let row = try rows.failableNext() {
      result.append(
        ChatRow(
          id: try int64Value(row, "chat_rowid") ?? 0,
          identifier: try stringValue(row, "chat_identifier"),
          name: try stringValue(row, "name"),
          service: try stringValue(row, "service_name"),
          lastMessageAt: try appleDate(from: int64Value(row, "last_date")),
          accountID: try stringValue(row, "account_id").nilIfEmpty,
          accountLogin: try stringValue(row, "account_login").nilIfEmpty,
          lastAddressedHandle: try stringValue(row, "last_addressed_handle").nilIfEmpty
        ))
    }
    return result
  }

  private func chat(from row: ChatRow, unreadCount: Int?) -> Chat {
    Chat(
      id: row.id,
      identifier: row.identifier,
      name: row.name,
      service: row.service,
      lastMessageAt: row.lastMessageAt,
      accountID: row.accountID,
      accountLogin: row.accountLogin,
      lastAddressedHandle: row.lastAddressedHandle,
      unreadCount: supportsUnreadState ? unreadCount ?? 0 : nil
    )
  }

  private func unreadCounts(for chatIDs: [Int64], db: Connection) throws -> [Int64: Int] {
    guard supportsUnreadState else { return [:] }
    var result: [Int64: Int] = [:]
    // Stay below SQLite builds with the traditional 999-variable limit.
    var offset = 0
    while offset < chatIDs.count {
      let end = min(offset + 500, chatIDs.count)
      let chunk = Array(chatIDs[offset..<end])
      let query = UnreadMessagesQuery(store: self, chatIDs: chunk)
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      var unreadMessageIDsByChat: [Int64: Set<Int64>] = [:]
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: nil
        )
        let reaction = decodeReaction(
          associatedType: decoded.associatedType,
          associatedGUID: decoded.associatedGUID,
          text: decoded.text
        )
        let message = Message(
          rowID: decoded.rowID,
          chatID: decoded.chatID,
          sender: decoded.sender,
          text: decoded.text,
          date: decoded.date,
          isFromMe: decoded.isFromMe,
          service: decoded.service,
          handleID: decoded.handleID,
          attachmentsCount: decoded.attachments,
          guid: decoded.guid,
          balloonBundleID: decoded.balloonBundleID.nilIfEmpty,
          reaction: Message.ReactionMetadata(
            isReaction: reaction.isReaction,
            reactionType: reaction.reactionType,
            isReactionAdd: reaction.isReactionAdd,
            reactedToGUID: reaction.reactedToGUID
          )
        )
        var logicalRowID = message.rowID
        if isURLPreviewBalloon(message),
          let textMessage = try precedingTextMessageForURLPreview(message, db: db)
        {
          guard textMessage.isRead == false else { continue }
          logicalRowID = textMessage.rowID
        }
        unreadMessageIDsByChat[decoded.chatID, default: []].insert(logicalRowID)
      }
      for (chatID, rowIDs) in unreadMessageIDsByChat {
        result[chatID] = rowIDs.count
      }
      offset = end
    }
    return result
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
