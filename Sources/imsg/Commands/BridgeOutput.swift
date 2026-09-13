import Commander
import Foundation
import IMsgCore

/// Expand short expressive-send names (e.g. `invisibleink`, `confetti`) to the
/// full bundle identifiers Messages.app expects on `expressiveSendStyleID`.
/// Already-prefixed strings (anything starting with `com.apple.`) and unknown
/// names pass through untouched so the dylib can return its own error.
enum ExpressiveSendEffect {
  /// Bubble effects render on the message bubble itself.
  static let bubbleNames: Set<String> = ["impact", "loud", "gentle", "invisibleink"]

  /// Screen effects play a full-screen animation. Map the short name to the
  /// `CK<TitleCase>Effect` token used in the bundle id.
  static let screenNames: [String: String] = [
    "confetti": "Confetti",
    "lasers": "Lasers",
    "fireworks": "Fireworks",
    "balloons": "Balloons",
    "sparkles": "Sparkles",
    "spotlight": "Spotlight",
    "echo": "Echo",
    "love": "Love",
    "celebration": "Celebration",
  ]

  static func expand(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return raw }
    if trimmed.hasPrefix("com.apple.") { return trimmed }
    let key = trimmed.lowercased()
    if bubbleNames.contains(key) {
      return "com.apple.MobileSMS.expressivesend.\(key)"
    }
    if let token = screenNames[key] {
      return "com.apple.messages.effect.CK\(token)Effect"
    }
    return trimmed
  }
}

/// Helpers shared by all bridge-backed commands.
enum BridgeOutput {
  struct EmittedError: Error {}

  static func emit(_ data: [String: Any], runtime: RuntimeOptions, summary: String) {
    if runtime.jsonOutput {
      try? JSONLines.printObject(data)
    } else {
      StdoutWriter.writeLine(summary)
    }
  }

  static func emitError(_ message: String, runtime: RuntimeOptions) {
    if runtime.jsonOutput {
      try? JSONLines.printObject(["success": false, "error": message])
    } else {
      StdoutWriter.writeLine("error: \(message)")
    }
  }

  /// Invoke a bridge action and emit the result; emit then throw on failure.
  ///
  /// `finalize` runs after the action succeeds but before anything is emitted,
  /// so a command that performs follow-up work can fold that work's outcome
  /// into the single emitted object. Callers that pass no `finalize` emit the
  /// bridge payload unchanged.
  static func invokeAndEmit(
    action: BridgeAction,
    params: [String: Any],
    runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    },
    finalize: (([String: Any]) async -> [String: Any])? = nil,
    summary: (([String: Any]) -> String)
  ) async throws -> [String: Any] {
    let data: [String: Any]
    do {
      data = try await invokeBridge(action, params)
    } catch {
      emitError(String(describing: error), runtime: runtime)
      throw EmittedError()
    }
    // Outside the `do`: the action already succeeded, so follow-up work must
    // never be reported as an action failure.
    let payload = await finalize?(data) ?? data
    emit(payload, runtime: runtime, summary: summary(payload))
    return payload
  }
}

// MARK: - send-rich
