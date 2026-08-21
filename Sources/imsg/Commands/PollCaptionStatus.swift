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
enum PollCaptionStatus {
  /// No caption was requested (`--no-comment` / `suppress_comment: true`).
  static var suppressed: [String: Any] { ["requested": false, "sent": false] }

  /// The caption was requested and the transport accepted it.
  static var sent: [String: Any] { ["requested": true, "sent": true] }

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
    invokeBridge: (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async -> [String: Any] {
    guard let comment else {
      return data.merging(["comment": suppressed]) { _, new in new }
    }
    let status: [String: Any]
    do {
      _ = try await invokeBridge(
        .sendMessage,
        [
          "chatGuid": chat,
          "message": comment,
        ])
      status = sent
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
