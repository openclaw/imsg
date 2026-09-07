import Foundation

/// How long `imsg launch` waits for Messages.app to publish the bridge-ready
/// lock file before giving up.
///
/// A cold start after a crash, or a machine under load, can exceed the default.
/// Reporting that as a failure is actively harmful: a supervisor that relaunches
/// on a non-zero exit will start a second Messages.app while the first is still
/// coming up, and two injected instances then compete for the same bridge queue.
enum LaunchReadinessTimeout {
  /// Seconds to wait when nothing overrides it.
  static let defaultSeconds: TimeInterval = 15

  /// Upper bound, so a typo cannot hang a launch indefinitely.
  static let maximumSeconds: TimeInterval = 600

  /// Environment variable that overrides the default.
  static let environmentKey = "IMSG_LAUNCH_READY_TIMEOUT"

  /// Resolve the timeout, falling back to the default for anything unusable.
  static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TimeInterval {
    guard let raw = environment[environmentKey],
      let parsed = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
      parsed.isFinite, parsed > 0
    else {
      return defaultSeconds
    }
    return min(parsed, maximumSeconds)
  }
}
