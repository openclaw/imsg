import Foundation
import SQLite

func reactionPredicate(_ column: String) -> String {
  "(\(column) BETWEEN 2000 AND 2006 OR \(column) BETWEEN 3000 AND 3006)"
}

func nonReactionPredicate(_ column: String) -> String {
  "(\(column) IS NULL OR NOT \(reactionPredicate(column)))"
}

struct ChatMessagesQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64

  init(store: MessageStore, chatID: ChatID, limit: Int, filter: MessageFilter?) {
    self.selection = MessageRowSelection(store: store)
    let destinationCallerColumn =
      store.schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let reactionFilter =
      store.schema.hasReactionColumns
      ? " AND \(nonReactionPredicate("m.associated_message_type"))"
      : ""
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      \(MessageRowSelection.scopedChatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?\(reactionFilter)
      """
    var bindings: [Binding?] = [chatID.rawValue]

    if let filter {
      if let startDate = filter.startDate {
        sql += " AND m.date >= ?"
        bindings.append(MessageStore.appleEpoch(startDate))
      }
      if let endDate = filter.endDate {
        sql += " AND m.date < ?"
        bindings.append(MessageStore.appleEpoch(endDate))
      }
      if !filter.participants.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.participants.count).joined(
          separator: ",")
        sql +=
          " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
        for participant in filter.participants {
          bindings.append(participant)
        }
      }
    }

    sql += " ORDER BY m.date DESC, m.ROWID DESC LIMIT ?"
    bindings.append(limit)

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID.rawValue
  }
}

struct MessagesAfterQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64?

  init(
    store: MessageStore,
    afterRowID: MessageID,
    chatID: ChatID?,
    limit: Int,
    includeReactions: Bool
  ) {
    self.selection = MessageRowSelection(
      store: store, chatIDColumn: chatID == nil ? MessageRowSelection.canonicalChatID : nil)
    let reactionFilter: String
    if includeReactions || !store.schema.hasReactionColumns {
      reactionFilter = ""
    } else {
      reactionFilter =
        " AND \(nonReactionPredicate("m.associated_message_type"))"
    }
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      \(chatID == nil ? "" : MessageRowSelection.scopedChatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?\(reactionFilter)
      """
    var bindings: [Binding?] = [afterRowID.rawValue]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID.rawValue)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID?.rawValue
  }
}

struct LatestSentMessageQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64?

  init(store: MessageStore, text: String, chatID: ChatID?, since date: Date) {
    self.selection = MessageRowSelection(
      store: store, chatIDColumn: chatID == nil ? MessageRowSelection.canonicalChatID : nil)
    let bodyColumn = store.schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      \(chatID == nil ? "" : MessageRowSelection.scopedChatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.is_from_me = 1
        AND m.date >= ?
        AND (
          IFNULL(m.text, '') = ?
          OR (IFNULL(m.text, '') = '' AND \(bodyColumn) IS NOT NULL)
        )
      """
    var bindings: [Binding?] = [MessageStore.appleEpoch(date), text]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID.rawValue)
    }
    sql += " ORDER BY m.date DESC, m.ROWID DESC"

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID?.rawValue
  }
}
