import Foundation

public enum MessagesLauncherError: Error, CustomStringConvertible {
  case dylibNotFound(String)
  case launchFailed(String)
  case sipEnabled
  case sipStatusUnknown(String)
  case socketTimeout
  case socketError(String)
  case invalidResponse
  case commandNotPublished(String)
  case commandTimeout(String)

  public var description: String {
    switch self {
    case .dylibNotFound(let path):
      return "imsg-bridge-helper.dylib not found at \(path). Build with: make build-dylib"
    case .launchFailed(let reason):
      return "Failed to launch Messages.app: \(reason)"
    case .sipEnabled:
      return
        "System Integrity Protection (SIP) is enabled. "
        + "Refusing to inject into Messages.app. "
        + "Disable SIP in Recovery mode before using `imsg launch`."
    case .sipStatusUnknown(let details):
      return
        "Unable to determine SIP status. "
        + "Refusing to inject into Messages.app. "
        + "Details: \(details)"
    case .socketTimeout:
      // Resolved rather than stored: the case stays payload-free so external
      // `.socketTimeout` construction keeps compiling, and `waitForReady` is
      // only ever called with this same resolved value.
      let seconds = LaunchReadinessTimeout.resolve()
      return
        "Messages.app did not report the bridge ready within "
        + "\(String(format: "%g", seconds))s. It may still be starting; re-check "
        + "with `imsg status` before relaunching, and raise "
        + "\(LaunchReadinessTimeout.environmentKey) if this host is consistently "
        + "slower. If it never becomes ready, verify SIP is disabled and "
        + "Messages.app has the necessary permissions."
    case .socketError(let reason):
      return "IPC error: \(reason)"
    case .invalidResponse:
      return "Invalid response from Messages.app helper"
    case .commandNotPublished(let reason):
      return "Bridge command was not published: \(reason)"
    case .commandTimeout(let action):
      return "Timeout waiting for bridge command '\(action)'"
    }
  }
}
