import Foundation

/// Authoritative delivery state for a Messages mutation that did not return success.
public enum DeliveryDisposition: String, Sendable, Codable {
  /// The transport proved that the operation was never dispatched.
  case notStarted = "not_started"
  /// The transport no longer observes work, but cannot prove whether it ran.
  case mayHaveCompleted = "may_have_completed"
  /// The transport still observes work that can execute after the caller returns.
  case stillInFlight = "still_in_flight"
}

/// Transport that owns a delivery disposition.
public enum DeliveryTransport: String, Sendable, Codable {
  case bridgeV2 = "bridge_v2"
  case bridgeLegacy = "bridge_legacy"
  case appleScript = "applescript"
}

/// A typed, redacted failure emitted by the transport that owns dispatch.
///
/// Callers may retry or downgrade only when `retrySafe` is true. In particular,
/// downstream code must never infer retry safety by matching `description`.
public struct DeliveryFailure: Error, Sendable, Equatable, CustomStringConvertible,
  LocalizedError
{
  public let disposition: DeliveryDisposition
  public let transport: DeliveryTransport
  public let operation: String
  public let detail: String

  public init(
    disposition: DeliveryDisposition,
    transport: DeliveryTransport,
    operation: String,
    detail: String
  ) {
    self.disposition = disposition
    self.transport = transport
    self.operation = operation
    self.detail = Self.sanitize(detail)
  }

  public var retrySafe: Bool { disposition == .notStarted }

  public var description: String {
    let retryGuidance =
      retrySafe
      ? "The operation did not start; retry is safe."
      : "The operation may execute or may already have executed; retry is not safe."
    return
      "\(transport.rawValue) \(operation) failed (\(disposition.rawValue)): "
      + "\(detail) \(retryGuidance)"
  }

  public var errorDescription: String? { description }

  private static func sanitize(_ value: String) -> String {
    let singleLine =
      value
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = String(singleLine.prefix(512))
    return bounded.isEmpty ? "No additional diagnostic was available." : bounded
  }
}

enum BridgeRequestQueueState: Equatable {
  case unclaimed
  case claimed
  case unreadable
  case absent
}

struct BridgeRequestPublication: Sendable {
  let id: String
  let action: BridgeAction
  let inboxDirectory: String
  let requestPath: String
  let responsePath: String
}
