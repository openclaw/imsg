import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

// A poll's question is only ever visible via the caption message imsg sends
// after the balloon, so a dropped caption leaves a question-less poll on screen.
// These tests pin the contract that `poll send` reports that outcome instead of
// returning a bare success the caller cannot distinguish from a complete send.

private let captionFailure = DeliveryFailure(
  disposition: .mayHaveCompleted,
  transport: .bridgeV2,
  operation: "send_message",
  detail: "The bridge response deadline expired."
)

private let retrySafeCaptionFailure = DeliveryFailure(
  disposition: .notStarted,
  transport: .bridgeV2,
  operation: "send_message",
  detail: "The bridge rejected the request before dispatch."
)

private func pollSendValues(
  extraOptions: [String: [String]] = [:],
  flags: Set<String> = []
) -> ParsedValues {
  var options: [String: [String]] = [
    "chat": ["iMessage;-;+15551234567"],
    "question": ["Dinner?"],
    "option": ["Pizza", "Sushi"],
  ]
  for (key, value) in extraOptions { options[key] = value }
  return ParsedValues(positional: ["send"], options: options, flags: flags)
}

/// Runs `poll send` with a bridge whose caption (second) call optionally throws,
/// returning the decoded JSON object the command emitted.
private func runPollSend(
  values: ParsedValues,
  captionError: Error? = nil,
  verification: PollCaptionStatus.VerificationOutcome = .delivered
) async throws -> (json: [String: Any], calls: Int, output: String) {
  let runtime = RuntimeOptions(parsedValues: values)
  var calls = 0
  let (output, _) = try await StdoutCapture.capture {
    try await PollCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, _ in
        calls += 1
        if action == .sendMessage, let captionError {
          throw captionError
        }
        return ["messageGuid": action == .sendMessage ? "caption-guid" : "poll-guid"]
      },
      verifyCaption: { _ in verification }
    )
  }
  let line = output.split(separator: "\n").last.map(String.init) ?? ""
  let json =
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
  return (json, calls, output)
}

@Test
func pollSendReportsCaptionDeliveryWhenItLands() async throws {
  let (json, calls, _) = try await runPollSend(values: pollSendValues(flags: ["jsonOutput"]))

  #expect(calls == 2)
  #expect(json["messageGuid"] as? String == "poll-guid")
  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == true)
  #expect(comment["sent"] as? Bool == true)
  #expect(comment["verified"] as? Bool == true)
  #expect(comment["error"] == nil)
}

@Test
func pollSendReportsUnknownWhenCaptionVerificationExpires() async throws {
  // The bridge acknowledged the send, but the row was not confirmed before
  // the deadline. It may still arrive, so this must not become `sent: false`.
  let (json, calls, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    verification: .unknown
  )

  #expect(calls == 2)
  #expect(json["messageGuid"] as? String == "poll-guid")
  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == true)
  #expect(comment["sent"] is NSNull)
  #expect(comment["verified"] as? Bool == false)
  #expect(comment["disposition"] as? String == "may_have_completed")
  #expect(comment["retry_safe"] as? Bool == false)
}

@Test
func pollSendReportsRecordedCaptionFailureWithoutInferringRetrySafety() async throws {
  let (json, _, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    verification: .failed
  )

  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["sent"] as? Bool == false)
  #expect(comment["verified"] as? Bool == false)
  #expect(comment["retry_safe"] == nil)
}

@Test
func pollSendOmitsVerifiedWhenTheCheckCannotRun() async throws {
  // No readable database: we did not look, so we claim neither outcome.
  let (json, _, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    verification: .unavailable
  )

  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["sent"] is NSNull)
  #expect(comment["verified"] == nil)
  #expect(comment["error"] == nil)
}

@Test
func pollSendReportsCaptionFailureInsteadOfSwallowingIt() async throws {
  let (json, calls, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    captionError: captionFailure
  )

  // The poll itself still succeeded, so the guid survives and the command does
  // not throw — re-sending the pair would duplicate the balloon.
  #expect(calls == 2)
  #expect(json["messageGuid"] as? String == "poll-guid")

  // …but the transport cannot prove whether the caption eventually landed.
  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == true)
  #expect(comment["sent"] is NSNull)
  #expect(comment["disposition"] as? String == "may_have_completed")
  #expect(comment["retry_safe"] as? Bool == false)
  let error = try #require(comment["error"] as? String)
  #expect(error.contains("The bridge response deadline expired."))
}

@Test
func pollSendReportsCaptionFailureForUntypedErrors() async throws {
  struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
  let (json, _, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    captionError: Boom()
  )

  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["sent"] is NSNull)
  #expect(comment["error"] as? String == "boom")
  // No transport disposition to report when the error is not a DeliveryFailure.
  #expect(comment["disposition"] == nil)
}

@Test
func pollSendReportsNotStartedCaptionAsRetrySafe() async throws {
  let (json, _, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    captionError: retrySafeCaptionFailure
  )

  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["sent"] as? Bool == false)
  #expect(comment["disposition"] as? String == "not_started")
  #expect(comment["retry_safe"] as? Bool == true)
}

@Test
func pollSendReportsStillInFlightCaptionAsUnknown() async throws {
  let failure = DeliveryFailure(
    disposition: .stillInFlight,
    transport: .bridgeV2,
    operation: "send_message",
    detail: "The bridge still owns the request."
  )
  let (json, _, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput"]),
    captionError: failure
  )

  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["sent"] is NSNull)
  #expect(comment["disposition"] as? String == "still_in_flight")
  #expect(comment["retry_safe"] as? Bool == false)
}

@Test
func pollSendMarksSuppressedCaptionAsNotRequested() async throws {
  let (json, calls, _) = try await runPollSend(
    values: pollSendValues(flags: ["jsonOutput", "noComment"])
  )

  #expect(calls == 1)
  let comment = try #require(json["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == false)
  #expect(comment["sent"] as? Bool == false)
  #expect(comment["error"] == nil)
}

@Test
func pollSendHumanSummaryPreservesUnknownDelivery() async throws {
  let (_, _, output) = try await runPollSend(
    values: pollSendValues(),
    captionError: captionFailure
  )

  #expect(output.contains("poll: sent (guid=poll-guid)"))
  #expect(output.contains("caption delivery UNKNOWN"))
  #expect(output.contains("do not retry automatically"))
  #expect(!output.contains("caption NOT delivered"))
}

@Test
func pollSendHumanSummaryAdvisesRetryOnlyWhenSafe() async throws {
  let (_, _, output) = try await runPollSend(
    values: pollSendValues(),
    captionError: retrySafeCaptionFailure
  )

  #expect(output.contains("caption NOT delivered"))
  #expect(output.contains("re-send the caption only, never the poll"))
}

@Test
func pollSendHumanSummaryDoesNotInferRetrySafetyFromRecordedFailure() async throws {
  let (_, _, output) = try await runPollSend(
    values: pollSendValues(),
    verification: .failed
  )

  #expect(output.contains("caption NOT delivered"))
  #expect(output.contains("automatic retry is not known to be safe"))
  #expect(!output.contains("re-send the caption only"))
}

@Test
func pollSendHumanSummaryStaysQuietWhenCaptionLands() async throws {
  let (_, _, output) = try await runPollSend(values: pollSendValues())

  #expect(output.contains("poll: sent (guid=poll-guid)"))
  #expect(!output.contains("caption NOT delivered"))
}

// MARK: - The verifier itself

@Test
func verifyCaptionDoesNotGuessWithoutAStore() async throws {
  // No store means the check never ran. That must stay distinct from a
  // negative verdict, or callers read "we did not look" as "it never arrived".
  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "caption-guid", chatGUID: "iMessage;-;+15551234567", store: nil)
  #expect(result == .unavailable)
}

@Test
func verifyCaptionDoesNotGuessWithoutAGuidToLookFor() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "", chatGUID: "iMessage;-;+15551234567", store: store)
  #expect(result == .unavailable)
}

@Test
func captionOutcomeRejectsARowMessagesRecordedAsFailed() async throws {
  // A row existing is not delivery. Messages writes a row for a failed send
  // too, and calling that verified is the exact false success this whole
  // status object exists to remove.
  #expect(PollCaptionStatus.captionOutcome(for: .failed) == .failed)
}

@Test
func captionOutcomeKeepsWaitingWhileTheSendIsPending() async throws {
  // unknown means "no verdict yet" — the caller keeps polling until the row flips
  // or the deadline passes, rather than banking an answer it does not have.
  #expect(PollCaptionStatus.captionOutcome(for: .pending) == .unknown)
}

@Test
func captionOutcomeRequiresDeliveredRatherThanLocallySent() async throws {
  #expect(PollCaptionStatus.captionOutcome(for: .sent) == .unknown)
  #expect(PollCaptionStatus.captionOutcome(for: .delivered) == .delivered)
}

@Test
func verifyCaptionToleratesGuidCasingBetweenBridgeAndDatabase() async throws {
  // messageSendStatus matches COLLATE NOCASE but messageBelongsToChat does
  // not, so a bridge GUID whose casing differs from the stored row must not
  // read back as a missing caption.
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("ALTER TABLE message ADD COLUMN is_sent INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_delivered INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN error INTEGER")
    // The row stores the GUID uppercased; the bridge will hand us lowercase.
    try db.run(
      "UPDATE message SET guid = ?, is_sent = 1, is_delivered = 1, error = 0 WHERE ROWID = 5",
      "CAPTION-GUID")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }

  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "caption-guid",
    chatGUID: "iMessage;-;+123",
    store: store,
    timeout: 0.5
  )
  #expect(result == .delivered)
}

@Test
func verifyCaptionKeepsLocallySentRowUnknownUntilDelivered() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("ALTER TABLE message ADD COLUMN is_sent INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_delivered INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN error INTEGER")
    try db.run(
      "UPDATE message SET guid = ?, is_sent = 1, is_delivered = 0, error = 0 WHERE ROWID = 5",
      "SENT-GUID")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }

  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "sent-guid",
    chatGUID: "iMessage;-;+123",
    store: store,
    timeout: 0.2
  )
  #expect(result == .unknown)
}

@Test
func verifyCaptionReportsAnAbsentRowAsUnknown() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "never-sent-guid",
    chatGUID: "iMessage;-;+15551234567",
    store: store,
    timeout: 0.2
  )
  #expect(result == .unknown)
}

@Test
func verifyCaptionReportsARecordedFailureSeparatelyFromTimeout() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("ALTER TABLE message ADD COLUMN is_sent INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN error INTEGER")
    try db.run(
      "UPDATE message SET guid = ?, is_sent = 0, error = 1 WHERE ROWID = 5", "FAILED-GUID")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }

  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "failed-guid",
    chatGUID: "iMessage;-;+123",
    store: store,
    timeout: 0.5
  )
  #expect(result == .failed)
}

@Test
func verifyCaptionReportsAPendingRowAtDeadlineAsUnknown() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("ALTER TABLE message ADD COLUMN is_sent INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN error INTEGER")
    try db.run(
      "UPDATE message SET guid = ?, is_sent = 0, error = 0 WHERE ROWID = 5", "PENDING-GUID")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }

  let result = await PollCaptionStatus.verifyCaption(
    captionGUID: "pending-guid",
    chatGUID: "iMessage;-;+123",
    store: store,
    timeout: 0.2
  )
  #expect(result == .unknown)
}

// MARK: - RPC surface

/// Runs `poll.send` over the RPC server, returning the response result object.
private func runRPCPollSend(
  suppressComment: Bool = false,
  captionError: Error? = nil,
  verification: PollCaptionStatus.VerificationOutcome = .delivered
) async throws -> [String: Any] {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      if action == .sendMessage, let captionError {
        throw captionError
      }
      return ["messageGuid": action == .sendMessage ? "caption-guid" : "poll-guid"]
    },
    verifyCaption: { _, _, _ in verification }
  )

  let suppress = suppressComment ? #","suppress_comment":true"# : ""
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Dinner?","options":["Pizza","Sushi"]"#
      + suppress + #"}}"#
  )

  let response = try #require(output.responses.last)
  return try #require(response["result"] as? [String: Any])
}

@Test
func rpcPollSendReportsCaptionDeliveryWhenItLands() async throws {
  let result = try await runRPCPollSend()

  #expect(result["ok"] as? Bool == true)
  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == true)
  #expect(comment["sent"] as? Bool == true)
  #expect(comment["verified"] as? Bool == true)
}

@Test
func rpcPollSendReportsUnknownWhenCaptionVerificationExpires() async throws {
  let result = try await runRPCPollSend(verification: .unknown)

  // The balloon landed, so the send is still a success…
  #expect(result["ok"] as? Bool == true)
  // …but a late caption may still arrive, so delivery remains unknown.
  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["sent"] is NSNull)
  #expect(comment["verified"] as? Bool == false)
  #expect(comment["disposition"] as? String == "may_have_completed")
}

@Test
func rpcPollSendReportsRecordedCaptionFailureWithoutInferringRetrySafety() async throws {
  let result = try await runRPCPollSend(verification: .failed)

  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["sent"] as? Bool == false)
  #expect(comment["verified"] as? Bool == false)
  #expect(comment["retry_safe"] == nil)
}

@Test
func rpcPollSendReportsCaptionFailureWithoutFailingTheSend() async throws {
  let result = try await runRPCPollSend(captionError: captionFailure)

  // The balloon landed, so `ok` must stay true — a caller that retried on
  // `ok: false` would post a second poll.
  #expect(result["ok"] as? Bool == true)
  #expect(result["message_id"] as? String == "poll-guid")

  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == true)
  #expect(comment["sent"] is NSNull)
  #expect(comment["disposition"] as? String == "may_have_completed")
  #expect(comment["retry_safe"] as? Bool == false)
}

@Test
func rpcPollSendReportsRetrySafeCaptionFailure() async throws {
  let result = try await runRPCPollSend(captionError: retrySafeCaptionFailure)

  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["sent"] as? Bool == false)
  #expect(comment["disposition"] as? String == "not_started")
  #expect(comment["retry_safe"] as? Bool == true)
}

@Test
func rpcPollSendMarksSuppressedCaptionAsNotRequested() async throws {
  let result = try await runRPCPollSend(suppressComment: true)

  let comment = try #require(result["comment"] as? [String: Any])
  #expect(comment["requested"] as? Bool == false)
  #expect(comment["sent"] as? Bool == false)
}
