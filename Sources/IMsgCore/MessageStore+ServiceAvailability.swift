import Foundation
import SQLite

/// Resolved messaging service for a recipient, inferred from local `chat.db` history.
public enum HandleServiceAvailability: Sendable, Equatable {
  /// The recipient has at least one prior, non-errored iMessage handle.
  case imessage
  /// The recipient has only SMS handle history (no usable iMessage handle).
  case sms
  /// No usable handle history exists locally (e.g. a brand-new contact).
  case unknown
}

extension MessageStore {
  /// Infer the preferred service after applying the same region-aware phone
  /// normalization used by `MessageSender`.
  public func preferredService(
    forHandle handle: String,
    region: String
  ) throws -> HandleServiceAvailability {
    let normalized = PhoneNumberNormalizer().normalize(
      handle,
      region: region.isEmpty ? "US" : region
    )
    let normalizedAvailability = try preferredService(forHandle: normalized)
    if normalizedAvailability != .unknown || normalized == handle {
      return normalizedAvailability
    }
    return try preferredService(forHandle: handle)
  }

  /// Infer the preferred service for a direct recipient from local message history.
  ///
  /// Mirrors the heuristic used by mac_messages_mcp: a recipient "has iMessage"
  /// when `chat.db` contains a handle on the `iMessage`/`iMessageLite` service
  /// with at least one successfully delivered (non-errored) message. When only
  /// SMS handle history exists we report `.sms`; with no history we report
  /// `.unknown` so callers can fall back to their own default.
  public func preferredService(forHandle handle: String) throws -> HandleServiceAvailability {
    let candidates = Self.handleCandidates(handle)
    guard !candidates.isEmpty else { return .unknown }

    let columns = withConnectionColumns(table: "handle")
    guard columns.contains("service") else { return .unknown }
    let messageColumns = withConnectionColumns(table: "message")
    let hasErrorColumn = messageColumns.contains("error")
    let errorExpr = hasErrorColumn ? "COUNT(CASE WHEN m.error != 0 THEN 1 END)" : "0"

    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
    let sql = """
      SELECT IFNULL(h.service, '') AS service,
             COUNT(m.ROWID) AS text_count,
             \(errorExpr) AS error_count
      FROM handle h
      LEFT JOIN message m ON h.ROWID = m.handle_id
      WHERE h.id IN (\(placeholders))
      GROUP BY h.ROWID, h.service
      """
    let bindings: [Binding?] = candidates

    return try withConnection { db in
      let rows = try db.prepareRowIterator(sql, bindings: bindings)
      var sawSMS = false
      while let row = try rows.failableNext() {
        let service = try stringValue(row, "service")
        let textCount = try int64Value(row, "text_count") ?? 0
        let errorCount = try int64Value(row, "error_count") ?? 0
        let lowered = service.lowercased()
        if lowered == "imessage" || lowered == "imessagelite" {
          if errorCount < textCount {
            return .imessage
          }
        } else if lowered == "sms" {
          sawSMS = true
        }
      }
      return sawSMS ? .sms : .unknown
    }
  }

  private func withConnectionColumns(table: String) -> Set<String> {
    (try? withConnection { db in
      try MessageStore.tableColumns(connection: db, table: table)
    }) ?? []
  }

  /// Generate the handle-id variants Messages may have stored for a recipient.
  ///
  /// Emails are matched verbatim (lowercased). Phone numbers are reduced to
  /// digits and expanded to the bare, country-coded, and `+`-prefixed forms,
  /// matching mac_messages_mcp's `_get_phone_formats`.
  static func handleCandidates(_ handle: String) -> [String] {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    if trimmed.contains("@") {
      return [trimmed.lowercased()]
    }

    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return [trimmed] }

    var formats = [trimmed, digits]
    if digits.hasPrefix("1") && digits.count > 10 {
      formats.append(String(digits.dropFirst()))
      formats.append("+" + digits)
    } else if digits.count == 10 {
      formats.append("1" + digits)
      formats.append("+1" + digits)
    } else {
      formats.append("+" + digits)
    }

    var seen = Set<String>()
    return formats.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}
