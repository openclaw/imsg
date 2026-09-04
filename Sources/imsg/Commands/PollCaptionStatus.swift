import Foundation
import IMsgCore

/// The balloon and its question caption are separate sends. Keep caption failure
/// or uncertainty separate so callers never retry an already-created poll.
enum PollCaptionStatus {
  enum VerificationOutcome: Equatable, Sendable {
    case delivered
    case failed
    case unknown
    case unavailable
  }

  static var suppressed: [String: Any] { ["requested": false, "sent": false] }

  static var verificationUnavailable: [String: Any] {
    ["requested": true, "sent": NSNull()]
  }

  static var sentVerified: [String: Any] {
    ["requested": true, "sent": true, "verified": true]
  }

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

  // RPC mutations share one lane. Bound the extra verification wait so an
  // offline recipient does not hold every queued mutation for the CLI deadline.
  static let rpcVerifyTimeout: TimeInterval = 2

  static func verifyCaption(
    captionGUID: String,
    chatGUID: String,
    store: MessageStore?,
    timeout: TimeInterval = 8
  ) async -> VerificationOutcome {
    guard let store, !captionGUID.isEmpty, !chatGUID.isEmpty else { return .unavailable }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(max(0, timeout))
    repeat {
      if Task.isCancelled { return .unavailable }
      do {
        if let status = try store.messageSendStatus(guid: captionGUID),
          try store.messageBelongsToChat(messageGUID: captionGUID, chatGUID: chatGUID)
        {
          switch status.state {
          case .delivered: return .delivered
          case .failed: return .failed
          case .pending, .sent: break
          }
        }
      } catch {
        // The database became unreadable mid-check. That is "we could not
        // look", never "it did not arrive". Returning `.failed` here would report
        // a delivery verdict this code did not earn.
        return .unavailable
      }
      let nextPoll = clock.now + .milliseconds(100)
      try? await clock.sleep(until: min(nextPoll, deadline))
    } while clock.now < deadline
    return .unknown
  }

  /// Maps a verification outcome onto the reported status.
  static func status(
    forVerification outcome: VerificationOutcome, messageGUID: String
  ) -> [String: Any] {
    var status: [String: Any]
    switch outcome {
    case .delivered: status = sentVerified
    case .failed: status = deliveryFailed
    case .unknown: status = deliveryUnknown
    case .unavailable: status = verificationUnavailable
    }
    if !messageGUID.isEmpty { status["message_guid"] = messageGUID }
    return status
  }

  /// Finishes the caption before CLI output; the successful poll remains successful.
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
      status = self.status(forVerification: outcome, messageGUID: captionGUID)
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
