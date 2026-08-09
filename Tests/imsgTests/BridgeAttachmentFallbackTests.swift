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
