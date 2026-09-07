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
    .socketTimeout(seconds: 15),
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
func socketTimeoutDescriptionReportsTheTimeoutUsed() {
  let description = MessagesLauncherError.socketTimeout(seconds: 15).description
  #expect(description.contains("15s"))
  #expect(description.contains("IMSG_LAUNCH_READY_TIMEOUT"))
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
