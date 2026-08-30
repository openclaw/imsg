import Foundation
import IMsgCore

/// Delivery status for the plain caption message that carries a poll's question.
///
/// Messages never renders a poll's title on the balloon, so the caption *is* the
/// question as far as recipients are concerned. The caption is sent after the
/// poll and is deliberately best-effort — the poll already landed, and retrying
/// the pair would duplicate the balloon. Best-effort must not mean silent: a
/// dropped caption leaves a question-less poll on screen while the caller sees
/// nothing but success, so `poll send` reports the outcome in its result
/// payload instead of leaving it on stderr where machine callers never look.
///
/// Shape (`comment` key on both the CLI JSON object and the RPC result):
/// - `requested` — whether a caption was supposed to be sent at all.
/// - `sent` — whether it landed.
/// - `error` — redacted failure text, only when `requested && !sent`.
/// - `disposition` / `retry_safe` — from ``DeliveryFailure`` when the transport
///   reported one, so callers decide re-send safety from the disposition rather
///   than by matching the message.
/// - `verified` — present when the caption row was looked for in the target
///   chat. A bridge acknowledgement only proves the transport accepted the
///   send, so `sent` is not reported true on an acknowledgement alone when the
///   row can be checked. Absent means the check could not run at all.
enum PollCaptionStatus {
  /// No caption was requested (`--no-comment` / `suppress_comment: true`).
  static var suppressed: [String: Any] { ["requested": false, "sent": false] }

  /// The caption was requested and the transport accepted it, but the row
  /// could not be checked (no readable database, or the bridge returned no
  /// GUID to look for). `verified` is absent: we did not look, so we do not
  /// claim either way.
  static var sent: [String: Any] { ["requested": true, "sent": true] }

  /// The caption was accepted *and* its row was found in the target chat.
  static var sentVerified: [String: Any] {
    ["requested": true, "sent": true, "verified": true]
  }

  /// The transport accepted the caption but its row never appeared in the
  /// target chat. Reported as not sent — a caption that never persisted leaves
  /// exactly the question-less balloon this status exists to expose — and
  /// carries the transport's own vocabulary for "cannot prove it ran".
  static var acceptedButMissing: [String: Any] {
    [
      "requested": true,
      "sent": false,
      "verified": false,
      "error":
        "The bridge accepted the caption but it never reached a sent state in the target chat.",
      "disposition": DeliveryDisposition.mayHaveCompleted.rawValue,
      "retry_safe": false,
    ]
  }

  /// The caption was requested and did not land.
  static func failed(_ error: Error) -> [String: Any] {
    var status: [String: Any] = ["requested": true, "sent": false]
    if let failure = error as? DeliveryFailure {
      status["error"] = failure.description
      status["disposition"] = failure.disposition.rawValue
      status["retry_safe"] = failure.retrySafe
    } else {
      status["error"] = String(describing: error)
    }
    return status
  }

  /// True when `status` describes a caption that was wanted but never arrived.
  static func isUndelivered(_ status: [String: Any]) -> Bool {
    (status["requested"] as? Bool) == true && (status["sent"] as? Bool) != true
  }

  /// Waits for a caption row to appear in the target chat.
  ///
  /// Mirrors ``SentMessageVerifier``: poll the database until the row shows up
  /// or the deadline passes, because Messages persists an accepted send
  /// asynchronously. Returns `nil` when the check cannot run — a missing store
  /// or an empty GUID is "we did not look", never "it did not arrive".
  /// Bound for the JSON-RPC surface. Mutations there are drained by a single
  /// worker, so a caption that never lands would otherwise hold the lane for
  /// the full CLI deadline and stall every mutation queued behind it. Rows
  /// normally appear well inside a second; timing out here reports
  /// `may_have_completed`, which tells callers not to retry, so a pessimistic
  /// bound costs honesty about certainty rather than causing duplicate sends.
  static let rpcVerifyTimeout: TimeInterval = 2

  /// Reads a caption row's send state. A row existing is not delivery: Messages
  /// records failed and still-pending sends as rows too, and reporting either
  /// as a delivered caption would recreate exactly the false success this
  /// status object exists to remove.
  ///
  /// - Returns: `true` once Messages reports the row sent or delivered, `false`
  ///   when it recorded a failure — waiting cannot change that — and `nil`
  ///   while the send is still pending and may yet flip either way.
  static func captionOutcome(for state: MessageSendState) -> Bool? {
    switch state {
    case .sent, .delivered: return true
    case .failed: return false
    case .pending: return nil
    }
  }

  static func verifyCaption(
    captionGUID: String,
    chatGUID: String,
    store: MessageStore?,
    timeout: TimeInterval = 8
  ) async -> Bool? {
    guard let store, !captionGUID.isEmpty, !chatGUID.isEmpty else { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Task.isCancelled { return nil }
      do {
        // `messageSendStatus` matches GUIDs COLLATE NOCASE but
        // `messageBelongsToChat` does not, so hand the membership check the
        // row's own GUID rather than the bridge's casing. Otherwise a caption
        // that plainly landed reads back as missing.
        if let status = try store.messageSendStatus(guid: captionGUID) {
          let rowGUID = status.guid.isEmpty ? captionGUID : status.guid
          if try store.messageBelongsToChat(messageGUID: rowGUID, chatGUID: chatGUID),
            let outcome = captionOutcome(for: status.state)
          {
            return outcome
          }
        }
      } catch {
        // The database became unreadable mid-check. That is "we could not
        // look", never "it did not arrive" — returning false here would report
        // a delivery verdict this code did not earn.
        return nil
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return false
  }

  /// Maps a verification outcome onto the reported status.
  static func status(forVerification verified: Bool?) -> [String: Any] {
    switch verified {
    case true: return sentVerified
    case false: return acceptedButMissing
    case nil: return sent
    }
  }

  /// Sends the caption that carries a poll's question and folds the outcome into
  /// the poll payload under `comment`. Pass `comment: nil` when it is suppressed.
  ///
  /// Best-effort, mirroring the RPC path: the poll already delivered, so a
  /// caption failure must not fail the command — re-sending would duplicate the
  /// balloon. Best-effort is not the same as silent, though, so the outcome
  /// rides along in the emitted object; stderr keeps the human-facing note.
  static func sendCaption(
    after data: [String: Any],
    chat: String,
    comment: String?,
    invokeBridge: (BridgeAction, [String: Any]) async throws -> [String: Any],
    verify: ((_ captionGUID: String) async -> Bool?)? = nil
  ) async -> [String: Any] {
    guard let comment else {
      return data.merging(["comment": suppressed]) { _, new in new }
    }
    let status: [String: Any]
    do {
      let response = try await invokeBridge(
        .sendMessage,
        [
          "chatGuid": chat,
          "message": comment,
        ])
      let captionGUID = (response["messageGuid"] as? String) ?? ""
      let verified = verify == nil ? nil : await verify?(captionGUID) ?? nil
      status = self.status(forVerification: verified)
      if verified == false {
        FileHandle.standardError.write(
          Data("[imsg] poll send: caption \(captionGUID) never appeared in \(chat)\n".utf8))
      }
    } catch {
      let pollGuid = (data["messageGuid"] as? String) ?? ""
      let pollDescription = pollGuid.isEmpty ? "queued poll" : "poll \(pollGuid)"
      FileHandle.standardError.write(
        Data("[imsg] poll send: comment echo failed for \(pollDescription): \(error)\n".utf8))
      status = failed(error)
    }
    return data.merging(["comment": status]) { _, new in new }
  }
}
