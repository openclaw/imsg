import Foundation
import Testing

@testable import IMsgCore

#if os(macOS)
  private final class RunnerSpy: @unchecked Sendable {
    private(set) var services: [String] = []
    private(set) var useChatFlags: [String] = []
    var firstFailure: DeliveryDisposition?

    func run(_ source: String, _ arguments: [String]) throws {
      // arguments[2] is the service rawValue.
      let service = arguments[2]
      services.append(service)
      useChatFlags.append(arguments[6])
      if let firstFailure, services.count == 1 {
        throw DeliveryFailure(
          disposition: firstFailure,
          transport: .appleScript,
          operation: "send",
          detail: "simulated transport phase"
        )
      }
    }
  }

  @Test
  func smsFallbackRetriesOverSMSForPhoneRecipient() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "+15551234567",
      text: "hi",
      service: .auto
    )

    try sender.send(options)

    #expect(spy.services == ["imessage", "sms"])
  }

  @Test
  func existingDirectChatFallsBackToSMSBuddyOnlyWhenNotStarted() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)

    try sender.send(
      MessageSendOptions(
        recipient: "+15551234567",
        text: "hi",
        service: .auto,
        chatGUID: "any;-;+15551234567",
        allowSMSFallback: true
      )
    )

    #expect(spy.services == ["auto", "sms"])
    #expect(spy.useChatFlags == ["1", "0"])
  }

  @Test
  func smsFallbackDoesNotOverrideExplicitIMessage() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "+15551234567",
      text: "hi",
      service: .imessage,
      allowSMSFallback: true
    )

    #expect(throws: DeliveryFailure.self) {
      try sender.send(options)
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func smsFallbackDisabledRethrowsOriginalError() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "+15551234567",
      text: "hi",
      service: .auto,
      allowSMSFallback: false
    )

    #expect(throws: DeliveryFailure.self) {
      try sender.send(options)
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func smsFallbackDoesNotEngageForEmailRecipient() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "friend@example.com",
      text: "hi",
      service: .imessage,
      allowSMSFallback: true
    )

    #expect(throws: DeliveryFailure.self) {
      try sender.send(options)
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func smsFallbackDoesNotEngageForChatTarget() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "",
      text: "hi",
      service: .imessage,
      chatGUID: "iMessage;+;chat123",
      allowSMSFallback: true
    )

    #expect(throws: DeliveryFailure.self) {
      try sender.send(options)
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func smsFallbackDoesNotEngageForAttachmentSend() throws {
    let spy = RunnerSpy()
    spy.firstFailure = .notStarted
    let sender = MessageSender(
      runner: spy.run,
      attachmentsSubdirectoryProvider: {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      }
    )
    let attachment = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try Data("photo".utf8).write(to: attachment)
    defer { try? FileManager.default.removeItem(at: attachment) }
    let options = MessageSendOptions(
      recipient: "+15551234567",
      text: "hi",
      attachmentPath: attachment.path,
      service: .auto,
      allowSMSFallback: true
    )

    #expect(throws: DeliveryFailure.self) {
      try sender.send(options)
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func successfulFirstSendDoesNotRetry() throws {
    let spy = RunnerSpy()
    let sender = MessageSender(runner: spy.run)
    let options = MessageSendOptions(
      recipient: "+15551234567",
      text: "hi",
      service: .imessage,
      allowSMSFallback: true
    )

    try sender.send(options)

    #expect(spy.services == ["imessage"])
  }

  @Test
  func postDispatchFailureNeverFallsBackToSMS() {
    let spy = RunnerSpy()
    spy.firstFailure = .mayHaveCompleted
    let sender = MessageSender(runner: spy.run)

    #expect(throws: DeliveryFailure.self) {
      try sender.send(
        MessageSendOptions(recipient: "+15551234567", text: "hi", service: .auto)
      )
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func timeoutOutcomeNeverFallsBackToSMS() {
    let spy = RunnerSpy()
    spy.firstFailure = .mayHaveCompleted
    let sender = MessageSender(runner: spy.run)

    do {
      try sender.send(
        MessageSendOptions(recipient: "+15551234567", text: "hi", service: .auto)
      )
      Issue.record("expected timeout-shaped delivery failure")
    } catch let failure as DeliveryFailure {
      #expect(failure.disposition == .mayHaveCompleted)
      #expect(!failure.retrySafe)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(spy.services == ["imessage"])
  }

  @Test
  func structuredAppleScriptPhaseControlsRetrySafety() {
    #expect(
      AppleScriptSendTransport.interpret(
        "IMSG_RESULT\tfailure\tnot_started\t-1728\n")
        == .failure(.notStarted, "Messages automation failed with AppleScript error -1728.")
    )
    #expect(
      AppleScriptSendTransport.interpret(
        "IMSG_RESULT\tfailure\tmay_have_completed\t-1712\n")
        == .failure(.mayHaveCompleted, "Messages automation failed with AppleScript error -1712.")
    )
    #expect(
      AppleScriptSendTransport.interpret("unexpected")
        == .failure(
          .mayHaveCompleted,
          "osascript exited without the structured delivery result."
        )
    )
  }

  @Test
  func productionScriptMarksDispatchBeforeEverySend() throws {
    var source = ""
    let sender = MessageSender(runner: { script, _ in source = script })

    try sender.send(
      MessageSendOptions(recipient: "+15551234567", text: "hi", service: .imessage)
    )

    #expect(source.contains("set dispatchPhase to \"pre_dispatch\""))
    #expect(source.components(separatedBy: "set dispatchPhase to \"dispatch_started\"").count == 5)
    #expect(source.contains("IMSG_RESULT"))
    #expect(source.contains("not_started"))
    #expect(source.contains("may_have_completed"))
  }
#endif
