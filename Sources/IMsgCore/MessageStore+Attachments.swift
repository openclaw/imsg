import Foundation
import SQLite

private struct AttachmentQuery {
  let sql: String
  let bindings: [Binding?]

  init(messageID: MessageID) {
    self.sql = """
      SELECT a.filename AS filename, a.transfer_name AS transfer_name, a.uti AS uti,
             a.mime_type AS mime_type, a.total_bytes AS total_bytes, a.is_sticker AS is_sticker
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      """
    self.bindings = [messageID.rawValue]
  }
}

private struct AudioTranscriptionQuery {
  let sql: String
  let bindings: [Binding?]

  init(messageID: MessageID) {
    self.sql = """
      SELECT a.user_info
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      ORDER BY a.ROWID ASC
      """
    self.bindings = [messageID.rawValue]
  }
}

extension MessageStore {
  public func attachments(
    for messageID: Int64,
    options: AttachmentQueryOptions = .default
  ) throws -> [AttachmentMeta] {
    let query = AttachmentQuery(messageID: MessageID(rawValue: messageID))
    return try withConnection { db in
      var metas: [AttachmentMeta] = []
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let filename = try stringValue(row, "filename")
        let transferName = try stringValue(row, "transfer_name")
        let uti = try stringValue(row, "uti")
        let mimeType = try stringValue(row, "mime_type")
        let totalBytes = try int64Value(row, "total_bytes") ?? 0
        let isSticker = try boolValue(row, "is_sticker")
        metas.append(
          AttachmentResolver.metadata(
            filename: filename,
            transferName: transferName,
            uti: uti,
            mimeType: mimeType,
            totalBytes: totalBytes,
            isSticker: isSticker,
            options: options
          ))
      }
      return metas
    }
  }

  func audioTranscription(for messageID: Int64) throws -> String? {
    guard schema.hasAttachmentUserInfo else { return nil }
    let query = AudioTranscriptionQuery(messageID: MessageID(rawValue: messageID))
    return try withConnection { db in
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let info = try dataValue(row, "user_info")
        guard !info.isEmpty else { continue }
        if let transcription = parseAudioTranscription(from: info) {
          return transcription
        }
      }
      return nil
    }
  }

  private func parseAudioTranscription(from data: Data) -> String? {
    do {
      let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
      guard
        let dict = plist as? [String: Any],
        let transcription = dict["audio-transcription"] as? String,
        !transcription.isEmpty
      else {
        return nil
      }
      return transcription
    } catch {
      return nil
    }
  }
}
