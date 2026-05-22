import Foundation
import IMsgCore

extension RPCServer {
  func handleMessageSendStatus(params: [String: Any], id: Any?) async throws {
    let guid = (stringParam(params["guid"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !guid.isEmpty else {
      throw RPCError.invalidParams("guid is required")
    }

    let checkedAt = Date()
    guard let status = try store.messageSendStatus(guid: guid) else {
      respond(
        id: id,
        result: [
          "ok": true,
          "guid": guid,
          "send_state": MessageSendState.pending.rawValue,
          "service": NSNull(),
          "checked_at": CLIISO8601.format(checkedAt),
          "status_fields": NSNull(),
        ])
      return
    }

    var result: [String: Any] = [
      "ok": true,
      "guid": status.guid,
      "send_state": status.state.rawValue,
      "service": status.service.isEmpty ? NSNull() : status.service,
      "checked_at": CLIISO8601.format(checkedAt),
      "status_fields": messageSendStatusFields(status),
    ]
    if let deliveredAt = status.dateDelivered {
      result["delivered_at"] = CLIISO8601.format(deliveredAt)
    }
    respond(id: id, result: result)
  }

  private func messageSendStatusFields(_ status: MessageSendStatus) -> [String: Any] {
    return [
      "is_sent": status.isSent,
      "is_delivered": status.isDelivered,
      "is_finished": status.isFinished,
      "error": status.error,
      "date_delivered": status.dateDelivered.map { CLIISO8601.format($0) } ?? NSNull(),
      "date_read": status.dateRead.map { CLIISO8601.format($0) } ?? NSNull(),
      "is_delayed": status.isDelayed,
      "is_prepared": status.isPrepared,
      "is_pending_satellite_send": status.isPendingSatelliteSend,
      "was_downgraded": status.wasDowngraded,
    ]
  }
}
