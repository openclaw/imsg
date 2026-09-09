import Foundation
import Testing

@testable import IMsgCore

@Test
func imCoreBridgeIsNotAvailableWithoutDylib() {
  // In the test environment there's no dylib built, so isAvailable should be false
  // unless one happens to exist at a search path. We test the shared instance exists.
  let bridge = IMCoreBridge.shared
  // Just verify the API exists and doesn't crash
  _ = bridge.isAvailable
}

@Test
func imCoreBridgeCheckAvailabilityReturnsDiagnostic() {
  let bridge = IMCoreBridge.shared
  let (_, message) = bridge.checkAvailability()
  // Should return a non-empty diagnostic message regardless of availability
  #expect(!message.isEmpty)
}

@Test
func messagesLauncherSharedInstanceExists() {
  let launcher = MessagesLauncher.shared
  // Verify the launcher can be accessed
  #expect(launcher.dylibPath.contains("imsg-bridge-helper.dylib"))
}

@Test
func messagesLauncherIsNotReadyWithoutInjection() {
  let launcher = MessagesLauncher.shared
  // Without actually launching Messages.app with injection, this should return false
  // (unless Messages happens to be running with our dylib, which is unlikely in CI)
  _ = launcher.isInjectedAndReady()
  // Just verify it doesn't crash
}

@Test
func messagesLauncherErrorDescriptions() {
  let errors: [MessagesLauncherError] = [
    .dylibNotFound("/fake/path"),
    .launchFailed("test reason"),
    .socketTimeout,
    .socketError("test error"),
    .invalidResponse,
  ]

  for error in errors {
    #expect(!error.description.isEmpty)
  }
}

@Test
func readinessTimeoutFallsBackToDefaultWithoutOverride() {
  #expect(
    LaunchReadinessTimeout.resolve(environment: [:])
      == LaunchReadinessTimeout.defaultSeconds)
}

@Test
func readinessTimeoutHonorsEnvironmentOverride() {
  #expect(
    LaunchReadinessTimeout.resolve(
      environment: ["IMSG_LAUNCH_READY_TIMEOUT": "45"]) == 45)
  #expect(
    LaunchReadinessTimeout.resolve(
      environment: ["IMSG_LAUNCH_READY_TIMEOUT": " 30.5 "]) == 30.5)
}

@Test
func readinessTimeoutRejectsUnusableOverrides() {
  for raw in ["", "abc", "0", "-5", "nan"] {
    #expect(
      LaunchReadinessTimeout.resolve(
        environment: ["IMSG_LAUNCH_READY_TIMEOUT": raw])
        == LaunchReadinessTimeout.defaultSeconds,
      "unusable override \(raw) should fall back to the default")
  }
}

@Test
func readinessTimeoutIsClampedToAnUpperBound() {
  #expect(
    LaunchReadinessTimeout.resolve(
      environment: ["IMSG_LAUNCH_READY_TIMEOUT": "99999"]) == 600)
}

@Test
func socketTimeoutDescriptionReportsTheTimeoutAndOverride() {
  let description = MessagesLauncherError.socketTimeout.description
  #expect(description.contains("\(String(format: "%g", LaunchReadinessTimeout.resolve()))s"))
  #expect(description.contains(LaunchReadinessTimeout.environmentKey))
  // The old text blamed SIP/permissions first; the cause is usually a slow start.
  #expect(description.contains("still be starting"))
}

/// Source-compatibility fixture.
///
/// `MessagesLauncherError` is public API in an exported library, so external
/// callers construct and match `.socketTimeout` without a payload. These are the
/// shapes such a caller uses; if the case ever gains a required associated
/// value this stops compiling, which is the point.
@Test
func socketTimeoutKeepsPayloadFreePublicConstruction() {
  let viaMemberSyntax: MessagesLauncherError = .socketTimeout
  let viaFullyQualified = MessagesLauncherError.socketTimeout
  let inCollection: [MessagesLauncherError] = [.socketTimeout]

  func classify(_ error: MessagesLauncherError) -> String {
    switch error {
    case .socketTimeout: return "timeout"
    default: return "other"
    }
  }

  #expect(classify(viaMemberSyntax) == "timeout")
  #expect(classify(viaFullyQualified) == "timeout")
  #expect(classify(inCollection[0]) == "timeout")

  // `throw` / `catch` is the other shape external callers rely on.
  func thrower() throws { throw MessagesLauncherError.socketTimeout }
  #expect(throws: MessagesLauncherError.self) { try thrower() }
}

@Test
func imCoreBridgeErrorDescriptions() {
  let errors: [IMCoreBridgeError] = [
    .dylibNotFound,
    .connectionFailed("test"),
    .chatNotFound("test-handle"),
    .operationFailed("test reason"),
  ]

  for error in errors {
    #expect(!error.description.isEmpty)
  }
}
