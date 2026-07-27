import Darwin
import Foundation

/// Bounded waits for external processes (ffmpeg, osascript, …).
/// Hung children must not block CLI/RPC work indefinitely.
public enum ProcessTimeout {
  /// Default bound for short external helpers (converters, osascript).
  public static let defaultTimeout: TimeInterval = 60

  /// Wait for `process` to exit, or terminate it when `timeout` elapses.
  /// - Returns: `true` if the process was killed because the deadline was reached.
  @discardableResult
  public static func waitUntilExit(
    _ process: Process,
    timeout: TimeInterval = defaultTimeout
  ) -> Bool {
    // Monotonic deadline so wall-clock jumps cannot stretch the bound.
    let clock = ContinuousClock()
    let bound = Duration.seconds(max(0.05, timeout))
    let deadline = clock.now + bound
    while process.isRunning {
      if clock.now >= deadline {
        terminate(process)
        process.waitUntilExit()
        return true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return false
  }

  /// SIGTERM the process, then SIGKILL process and process-group after grace.
  public static func terminate(_ process: Process) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    let ownsProcessGroup = getpgid(pid) == pid
    process.terminate()
    if ownsProcessGroup {
      kill(-pid, SIGTERM)
    }

    let clock = ContinuousClock()
    let killDeadline = clock.now + .milliseconds(500)
    while process.isRunning, clock.now < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(pid, SIGKILL)
    }
    // The leader may exit on SIGTERM while a descendant ignores it. Escalate
    // the captured group independently of the leader's state.
    if ownsProcessGroup {
      kill(-pid, SIGKILL)
    }
  }
}
