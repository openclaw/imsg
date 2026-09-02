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
/// - `sent` — whether it landed: `true`, `false`, or `null` when delivery is
///   unknown.
/// - `error` — redacted failure text when delivery failed or is unresolved.
/// - `disposition` / `retry_safe` — from ``DeliveryFailure`` when the transport
///   reported one, or conservatively synthesized when verification expires.
///   Callers decide re-send safety from these fields rather than by matching
///   the message.
/// - `verified` — present when the caption row was looked for in the target
///   chat. A bridge acknowledgement only proves the transport accepted the
///   send, so `sent` is not reported true on an acknowledgement alone when the
///   row can be checked. Absent means the check could not run at all.
enum PollCaptionStatus {
  enum VerificationOutcome: Equatable, Sendable {
    case delivered
    case failed
    case unknown
    case unavailable
  }

  /// No caption was requested (`--no-comment` / `suppress_comment: true`).
  static var suppressed: [String: Any] { ["requested": false, "sent": false] }

  /// The caption was requested and the transport accepted it, but the row
  /// could not be checked (no readable database, or the bridge returned no
  /// GUID to look for). `sent` is null and `verified` is absent: we did not
  /// look, so we do not claim either way.
  static var verificationUnavailable: [String: Any] {
    ["requested": true, "sent": NSNull()]
  }

  /// The caption was accepted *and* its row was found in the target chat.
  static var sentVerified: [String: Any] {
    ["requested": true, "sent": true, "verified": true]
  }

  /// The transport accepted the caption, but its row was absent or still
  /// pending when verification expired. This is explicitly unknown: Messages
  /// can persist or deliver the row after the deadline, so retrying could
  /// duplicate the caption.
  static var deliveryUnknown: [String: Any] {
    [
      "requested": true,
      "sent": NSNull(),
      "verified": false,
      "error":
        "The bridge accepted the caption, but delivery was not confirmed before the verification deadline.",
      "disposition": DeliveryDisposition.mayHaveCompleted.rawValue,
      "retry_safe": false,
    ]
  }

  /// Messages recorded the accepted caption row as failed.
  static var deliveryFailed: [String: Any] {
    [
      "requested": true,
      "sent": false,
      "verified": false,
      "error": "Messages recorded the caption send as failed.",
    ]
  }

  /// The caption transport returned an error. Only `not_started` proves it was
  /// not sent; every other typed disposition and every untyped error remain
  /// delivery-unknown.
  static func failed(_ error: Error) -> [String: Any] {
    var status: [String: Any] = ["requested": true, "sent": NSNull()]
    if let failure = error as? DeliveryFailure {
      if failure.retrySafe {
        status["sent"] = false
      }
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
    (status["requested"] as? Bool) == true && (status["sent"] as? Bool) == false
  }

  /// True when the caption may still arrive and must not be retried blindly.
  static func isDeliveryUnknown(_ status: [String: Any]) -> Bool {
    (status["requested"] as? Bool) == true && status["sent"] is NSNull
  }

  /// Waits for a caption row to appear in the target chat.
  ///
  /// Mirrors ``SentMessageVerifier``: poll the database until the row shows up
  /// or the deadline passes, because Messages persists an accepted send
  /// asynchronously. Returns `.unavailable` when the check cannot run. A
  /// missing store or empty GUID is "we did not look", never "it did not arrive".
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
  /// - Returns: `.delivered` once Messages reports the row sent or delivered,
  ///   `.failed` when it recorded a failure, and `.unknown` while the send is
  ///   still pending and may yet flip either way.
  static func captionOutcome(for state: MessageSendState) -> VerificationOutcome {
    switch state {
    case .sent, .delivered: return .delivered
    case .failed: return .failed
    case .pending: return .unknown
    }
  }

  static func verifyCaption(
    captionGUID: String,
    chatGUID: String,
    store: MessageStore?,
    timeout: TimeInterval = 8
  ) async -> VerificationOutcome {
    guard let store, !captionGUID.isEmpty, !chatGUID.isEmpty else { return .unavailable }
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Task.isCancelled { return .unavailable }
      do {
        // `messageSendStatus` matches GUIDs COLLATE NOCASE but
        // `messageBelongsToChat` does not, so hand the membership check the
        // row's own GUID rather than the bridge's casing. Otherwise a caption
        // that plainly landed reads back as missing.
        if let status = try store.messageSendStatus(guid: captionGUID) {
          let rowGUID = status.guid.isEmpty ? captionGUID : status.guid
          if try store.messageBelongsToChat(messageGUID: rowGUID, chatGUID: chatGUID) {
            let outcome = captionOutcome(for: status.state)
            if outcome != .unknown { return outcome }
          }
        }
      } catch {
        // The database became unreadable mid-check. That is "we could not
        // look", never "it did not arrive". Returning `.failed` here would report
        // a delivery verdict this code did not earn.
        return .unavailable
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return .unknown
  }

  /// Maps a verification outcome onto the reported status.
  static func status(forVerification outcome: VerificationOutcome) -> [String: Any] {
    switch outcome {
    case .delivered: return sentVerified
    case .failed: return deliveryFailed
    case .unknown: return deliveryUnknown
    case .unavailable: return verificationUnavailable
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
    verify: ((_ captionGUID: String) async -> VerificationOutcome)? = nil
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
      let outcome = await verify?(captionGUID) ?? .unavailable
      status = self.status(forVerification: outcome)
      if outcome == .unknown {
        FileHandle.standardError.write(
          Data(
            "[imsg] poll send: caption \(captionGUID) delivery was not verified in \(chat); automatic retry is unsafe\n"
              .utf8))
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
