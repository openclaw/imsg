import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func attachmentValues(
  transport: String = "auto",
  replyTo: String? = nil
) -> ParsedValues {
  var options: [String: [String]] = [
    "chat": ["iMessage;-;+15551234567"],
    "file": ["/tmp/photo.jpg"],
    "db": ["/nonexistent/imsg-fixture.db"],
    "transport": [transport],
  ]
  if let replyTo { options["replyTo"] = [replyTo] }
  return ParsedValues(positional: [], options: options, flags: [])
}

@Test
func attachmentAutoFallbackRequiresAuthoritativeNotStarted() async throws {
  let values = attachmentValues()
  let runtime = RuntimeOptions(parsedValues: values)
  var appleScriptCalled = false

  _ = try await StdoutCapture.capture {
    try await SendAttachmentCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, _ in
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "publication failed"
        )
      },
      stageAttachment: { _ in "/tmp/staged.jpg" },
      sendMessage: { _ in appleScriptCalled = true }
    )
  }

  #expect(appleScriptCalled)
}

@Test
func attachmentAutoNeverFallsBackAfterUncertainBridgeOutcome() async {
  let values = attachmentValues()
  let runtime = RuntimeOptions(parsedValues: values)
  var appleScriptCalled = false

  do {
    _ = try await StdoutCapture.capture {
      try await SendAttachmentCommand.run(
        values: values,
        runtime: runtime,
        invokeBridge: { action, _ in
          throw DeliveryFailure(
            disposition: .mayHaveCompleted,
            transport: .bridgeV2,
            operation: action.rawValue,
            detail: "response was lost"
          )
        },
        stageAttachment: { _ in "/tmp/staged.jpg" },
        sendMessage: { _ in appleScriptCalled = true }
      )
    }
    Issue.record("expected uncertain bridge failure")
  } catch is BridgeOutput.EmittedError {
    // Expected: the command already emitted its bridge diagnostic.
  } catch {
    Issue.record("unexpected error: \(error)")
  }

  #expect(!appleScriptCalled)
}

@Test
func attachmentExplicitBridgeAndRepliesRetainNoFallbackPolicy() async {
  for values in [
    attachmentValues(transport: "dylib"),
    attachmentValues(replyTo: "parent-guid"),
  ] {
    let runtime = RuntimeOptions(parsedValues: values)
    var appleScriptCalled = false
    do {
      _ = try await StdoutCapture.capture {
        try await SendAttachmentCommand.run(
          values: values,
          runtime: runtime,
          invokeBridge: { action, _ in
            throw DeliveryFailure(
              disposition: .notStarted,
              transport: .bridgeV2,
              operation: action.rawValue,
              detail: "publication failed"
            )
          },
          stageAttachment: { _ in "/tmp/staged.jpg" },
          sendMessage: { _ in appleScriptCalled = true }
        )
      }
      Issue.record("expected explicit bridge-only failure")
    } catch is BridgeOutput.EmittedError {
      // Expected.
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(!appleScriptCalled)
  }
}

@Test(arguments: ["auto", "applescript"], [false, true])
func attachmentFallbackSuppliesVerifiedDirectParticipant(transport: String, direct: Bool)
  async throws
{
  let path = try direct ? CommandTestDatabase.makePathDirectChat() : CommandTestDatabase.makePath()
  let chat = direct ? "iMessage;-;+123" : "iMessage;+;chat123"
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": [chat], "file": ["/synthetic/photo.jpg"], "transport": [transport], "db": [path],
    ],
    flags: [])
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendAttachmentCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in throw IMsgBridgeError.bridgeNotReady("synthetic unavailable helper")
      },
      stageAttachment: { $0 }, sendMessage: { captured = $0 })
  }
  #expect(captured?.chatGUID == chat)
  #expect(captured?.directParticipantTarget?.recipient == (direct ? "+123" : nil))
  #expect(
    captured?.directParticipantTarget?.accountID == (direct ? "iMessage;+;me@icloud.com" : nil))
}
