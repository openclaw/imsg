import SQLite

private func statsNonReactionPredicate(_ column: String) -> String {
  """
  (\(column) IS NULL OR (
    \(column) NOT BETWEEN 2000 AND 2006
    AND \(column) NOT BETWEEN 3000 AND 3006
  ))
  """
}

struct StatsQueryFilter {
  let whereClause: String
  let bindings: [Binding?]

  init(schema: MessageStoreSchema, chatID: Int64?) {
    var clauses: [String] = []
    var bindings: [Binding?] = []
    if schema.hasReactionColumns {
      clauses.append(statsNonReactionPredicate("m.associated_message_type"))
    }
    if let chatID {
      clauses.append("cmj.chat_id = ?")
      bindings.append(chatID)
    }
    self.whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
    self.bindings = bindings
  }
}

struct StatsMessageQuery {
  let sql: String
  let bindings: [Binding?]

  init(schema: MessageStoreSchema, chatID: Int64?) {
    let filter = StatsQueryFilter(schema: schema, chatID: chatID)
    let destinationColumn = schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let balloonColumn = schema.hasBalloonBundleIDColumn ? "m.balloon_bundle_id" : "NULL"
    let bodyColumn = schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    self.sql = """
      SELECT DISTINCT m.ROWID AS message_rowid,
             cmj.chat_id AS chat_id,
             IFNULL(c.chat_identifier, '') AS chat_identifier,
             COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), '') AS chat_name,
             IFNULL(c.service_name, '') AS chat_service,
             m.handle_id AS handle_id,
             IFNULL(h.id, '') AS sender,
             IFNULL(m.text, '') AS text,
             CASE WHEN \(balloonColumn) = '\(MessageStore.urlPreviewBalloonBundleID)'
                  THEN \(bodyColumn) ELSE NULL END AS body,
             m.date AS message_date,
             m.is_from_me AS is_from_me,
             IFNULL(m.service, '') AS message_service,
             IFNULL(\(destinationColumn), '') AS destination_caller_id,
             IFNULL(\(balloonColumn), '') AS balloon_bundle_id
      FROM message m
      JOIN (SELECT DISTINCT chat_id, message_id FROM chat_message_join) cmj
        ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      \(filter.whereClause)
      ORDER BY m.ROWID ASC, cmj.chat_id ASC
      """
    self.bindings = filter.bindings
  }
}

struct StatsMediaQuery {
  let sql: String
  let bindings: [Binding?]

  init(schema: MessageStoreSchema, chatID: Int64?) {
    let filter = StatsQueryFilter(schema: schema, chatID: chatID)
    self.sql = """
      SELECT DISTINCT a.ROWID AS attachment_id,
             cmj.chat_id AS chat_id,
             IFNULL(c.chat_identifier, '') AS chat_identifier,
             COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), '') AS chat_name,
             IFNULL(a.uti, '') AS uti,
             IFNULL(a.mime_type, '') AS mime_type,
             MAX(IFNULL(a.total_bytes, 0), 0) AS total_bytes
      FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      JOIN message m ON m.ROWID = maj.message_id
      JOIN (SELECT DISTINCT chat_id, message_id FROM chat_message_join) cmj
        ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      \(filter.whereClause)
      ORDER BY a.ROWID ASC, cmj.chat_id ASC
      """
    self.bindings = filter.bindings
  }
}

struct StatsPreviewQuery {
  let sql: String
  let bindings: [Binding?]

  init(schema: MessageStoreSchema, chatID: Int64?) {
    let filter = StatsQueryFilter(schema: schema, chatID: chatID)
    let previewDestination =
      schema.hasDestinationCallerID
      ? "preview.destination_caller_id" : "NULL"
    let previousDestination =
      schema.hasDestinationCallerID
      ? "previous.destination_caller_id" : "NULL"
    let previewBalloon = schema.hasBalloonBundleIDColumn ? "preview.balloon_bundle_id" : "NULL"
    let previousBalloon =
      schema.hasBalloonBundleIDColumn
      ? "previous.balloon_bundle_id" : "NULL"
    let previewBody = schema.hasAttributedBody ? "preview.attributedBody" : "NULL"
    let previousBody = schema.hasAttributedBody ? "previous.attributedBody" : "NULL"
    self.sql = """
      WITH base AS (
        SELECT cmj.chat_id, m.ROWID AS message_id
        FROM message m
        JOIN (SELECT DISTINCT chat_id, message_id FROM chat_message_join) cmj
          ON cmj.message_id = m.ROWID
        \(filter.whereClause)
      ), sequenced AS (
        SELECT chat_id, message_id,
               LAG(message_id) OVER (PARTITION BY chat_id ORDER BY message_id) AS previous_id
        FROM base
      )
      SELECT s.chat_id AS chat_id,
             preview.ROWID AS preview_rowid,
             preview.handle_id AS preview_handle_id,
             IFNULL(preview_handle.id, '') AS preview_sender,
             IFNULL(preview.text, '') AS preview_text,
             \(previewBody) AS preview_body,
             preview.date AS preview_date,
             preview.is_from_me AS preview_is_from_me,
             IFNULL(preview.service, '') AS preview_service,
             IFNULL(\(previewDestination), '') AS preview_destination_caller_id,
             IFNULL(\(previewBalloon), '') AS preview_balloon_bundle_id,
             previous.ROWID AS previous_rowid,
             previous.handle_id AS previous_handle_id,
             IFNULL(previous_handle.id, '') AS previous_sender,
             IFNULL(previous.text, '') AS previous_text,
             \(previousBody) AS previous_body,
             previous.date AS previous_date,
             previous.is_from_me AS previous_is_from_me,
             IFNULL(previous.service, '') AS previous_service,
             IFNULL(\(previousDestination), '') AS previous_destination_caller_id,
             IFNULL(\(previousBalloon), '') AS previous_balloon_bundle_id
      FROM sequenced s
      JOIN message preview ON preview.ROWID = s.message_id
      LEFT JOIN handle preview_handle ON preview_handle.ROWID = preview.handle_id
      LEFT JOIN message previous ON previous.ROWID = s.previous_id
      LEFT JOIN handle previous_handle ON previous_handle.ROWID = previous.handle_id
      WHERE \(previewBalloon) = '\(MessageStore.urlPreviewBalloonBundleID)'
      ORDER BY preview.ROWID ASC, s.chat_id ASC
      """
    self.bindings = filter.bindings
  }
}
