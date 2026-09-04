import Foundation
import Testing

@testable import IMsgCore

@Test(arguments: [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude])
func typingIndicatorRejectsInvalidDurationBeforeStarting(duration: Double) async {
  var didStart = false
  do {
    try await TypingIndicator.typeForDuration(
      chatIdentifier: "fixture-chat", duration: duration,
      startTyping: { _ in
        didStart = true
        throw CancellationError()
      },
      stopTyping: { _ in Issue.record("Invalid duration must not stop typing") },
      sleep: { _ in Issue.record("Invalid duration must not start a timer") })
    Issue.record("Expected an invalid duration error")
  } catch IMsgError.typingIndicatorFailed {
  } catch {
    Issue.record("Expected duration validation before starting, got \(error)")
  }
  #expect(!didStart)
}

@Test
func typingIndicatorStopsOnCancellation() async {
  var events: [String] = []

  do {
    try await TypingIndicator.typeForDuration(
      chatIdentifier: "iMessage;+;chat123",
      duration: 1,
      startTyping: { _ in events.append("start") },
      stopTyping: { _ in events.append("stop") },
      sleep: { _ in throw CancellationError() }
    )
    #expect(Bool(false))
  } catch is CancellationError {
    #expect(Bool(true))
  } catch {
    #expect(Bool(false))
  }

  #expect(events == ["start", "stop"])
}

@Test
func typingIndicatorStopsAfterNormalDuration() async throws {
  var events: [String] = []
  var didSleep = false

  try await TypingIndicator.typeForDuration(
    chatIdentifier: "iMessage;+;chat123",
    duration: 1,
    startTyping: { _ in events.append("start") },
    stopTyping: { _ in events.append("stop") },
    sleep: { _ in didSleep = true }
  )

  #expect(didSleep == true)
  #expect(events == ["start", "stop"])
}

@Test
func typingLookupCandidatesExpandAnyPrefixToServiceVariants() {
  let candidates = TypingIndicator.chatLookupCandidates(for: "any;-;+15551234567")

  #expect(
    candidates == [
      "any;-;+15551234567",
      "+15551234567",
      "iMessage;-;+15551234567",
      "iMessage;+;+15551234567",
      "SMS;-;+15551234567",
      "SMS;+;+15551234567",
      "any;+;+15551234567",
    ])
}

@Test
func typingLookupCandidatesAvoidDoublePrefixingDirectIdentifiers() {
  let candidates = TypingIndicator.chatLookupCandidates(for: " iMessage;-;user@example.com ")

  #expect(
    candidates == [
      "iMessage;-;user@example.com",
      "user@example.com",
      "iMessage;+;user@example.com",
      "SMS;-;user@example.com",
      "SMS;+;user@example.com",
      "any;-;user@example.com",
      "any;+;user@example.com",
    ])
}

@Test
func typingLookupCandidatesRejectBlankIdentifier() {
  #expect(TypingIndicator.chatLookupCandidates(for: "   ").isEmpty)
}

@Test
func typingDaemonUnavailableMessageExplainsTahoeEntitlementBlock() {
  let message = TypingIndicator.daemonUnavailableMessage()

  #expect(message.contains("imagent"))
  #expect(message.contains("macOS 26/Tahoe"))
  #expect(message.contains("Apple-private entitlements"))
  #expect(message.contains("imsg status"))
  #expect(message.contains("send"))
  #expect(message.contains("history"))
  #expect(message.contains("watch"))
}

#if os(macOS)
  @Test
  func typingBridgeWaitHasFiniteMonotonicBound() {
    let clock = ContinuousClock()
    let start = clock.now
    do {
      try TypingIndicator.waitForBridgeOperation(operation: "typing", timeout: 0.02) {
        try await Task.sleep(for: .seconds(10))
      }
      Issue.record("expected bounded bridge wait failure")
    } catch let failure as DeliveryFailure {
      #expect(failure.disposition == .stillInFlight)
      #expect(failure.retrySafe == false)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(start.duration(to: clock.now) < .seconds(1))
  }
#endif
