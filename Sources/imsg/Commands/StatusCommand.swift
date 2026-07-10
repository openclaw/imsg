import Commander
import Foundation
import IMsgCore

enum StatusCommand {
  static let spec = CommandSpec(
    name: "status",
    abstract: "Check availability of imsg advanced features",
    discussion: """
      Display the current status of imsg features and permissions.
      Shows which advanced features (typing indicators, read receipts) are
      available and provides setup instructions if needed.
      """,
    signature: CommandSignatures.withRuntimeFlags(CommandSignature()),
    usageExamples: [
      "imsg status",
      "imsg status --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()
    let sipStatus: String = {
      switch MessagesLauncher.currentSIPStatus() {
      case .enabled:
        return "enabled"
      case .disabled:
        return "disabled"
      case .unknown:
        return "unknown"
      }
    }()

    // Probe the bridge for v2 readiness + selector availability.
    var bridgeVersion: Int = 0
    var v2Ready: Bool = false
    var selectors: [String: Bool] = [:]
    if availability.available {
      do {
        let data = try await IMsgBridgeClient.shared.invoke(
          action: .status, params: [:], timeout: 3.0)
        bridgeVersion = (data["bridge_version"] as? Int) ?? 0
        v2Ready = (data["v2_ready"] as? Bool) ?? false
        if let raw = data["selectors"] as? [String: Bool] { selectors = raw }
      } catch {
        // Bridge probe failure is non-fatal.
      }
    }

    if runtime.jsonOutput {
      let payload = StatusPayload(
        version: IMsgVersion.current,
        basicFeatures: true,
        advancedFeatures: availability.available,
        typingIndicators: availability.available,
        readReceipts: availability.available,
        sip: sipStatus,
        message: availability.message,
        bridgeVersion: bridgeVersion,
        v2Ready: v2Ready,
        selectors: selectors,
        rpcMethods: kSupportedRPCMethods
      )
      try JSONLines.print(payload)
    } else {
      StdoutWriter.writeLine("imsg Status Report")
      StdoutWriter.writeLine("==================")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("Version:")
      StdoutWriter.writeLine("  \(IMsgVersion.current)")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("Basic features (send, receive, history):")
      StdoutWriter.writeLine("  Available")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("System Integrity Protection (SIP):")
      StdoutWriter.writeLine("  \(sipStatus)")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("Advanced features (typing, read receipts):")
      if availability.available {
        StdoutWriter.writeLine("  Available - IMCore bridge connected")
        StdoutWriter.writeLine(
          "  bridge version: v\(bridgeVersion)\(v2Ready ? " (v2 inbox active)" : "")")
        if !selectors.isEmpty {
          StdoutWriter.writeLine("  selectors:")
          for key in selectors.keys.sorted() {
            let ok = selectors[key] ?? false
            StdoutWriter.writeLine("    \(key): \(ok ? "✓" : "✗")")
          }
        }
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("Available bridge commands:")
        StdoutWriter.writeLine("  Send: imsg send-rich, send-multipart, send-attachment, tapback")
        StdoutWriter.writeLine("  Mutate: imsg edit, unsend, delete-message, notify-anyways")
        StdoutWriter.writeLine(
          "  Chat: imsg chat-create, chat-name, chat-photo, chat-add/remove-member, chat-leave/delete, chat-mark"
        )
        StdoutWriter.writeLine("  Introspect: imsg account, whois, nickname")
        StdoutWriter.writeLine("  Local DB: imsg search")
        StdoutWriter.writeLine("  Watch with events: imsg watch --bb-events")
      } else {
        StdoutWriter.writeLine("  Not available")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("To enable advanced features:")
        StdoutWriter.writeLine("  1. Disable System Integrity Protection (SIP)")
        StdoutWriter.writeLine("     - Restart Mac holding Cmd+R")
        StdoutWriter.writeLine("     - Open Terminal from Utilities menu")
        StdoutWriter.writeLine("     - Run: csrutil disable")
        StdoutWriter.writeLine("     - Restart normally")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("  2. Grant Full Disk Access")
        StdoutWriter.writeLine("     - System Settings > Privacy & Security > Full Disk Access")
        StdoutWriter.writeLine("     - Add Terminal or your terminal app")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("  3. Build and launch:")
        StdoutWriter.writeLine("     make build-dylib")
        StdoutWriter.writeLine("     imsg launch")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("macOS 26/Tahoe note:")
        StdoutWriter.writeLine(
          "  Advanced IMCore features may still be blocked by library validation"
        )
        StdoutWriter.writeLine(
          "  or imagent private entitlement checks. Basic commands still work."
        )
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("Note: Basic messaging features work without these steps.")
      }
    }
  }
}

private struct StatusPayload: Encodable {
  let version: String
  let basicFeatures: Bool
  let advancedFeatures: Bool
  let typingIndicators: Bool
  let readReceipts: Bool
  let sip: String
  let message: String
  let bridgeVersion: Int
  let v2Ready: Bool
  let selectors: [String: Bool]
  let rpcMethods: [String]

  enum CodingKeys: String, CodingKey {
    case version
    case basicFeatures = "basic_features"
    case advancedFeatures = "advanced_features"
    case typingIndicators = "typing_indicators"
    case readReceipts = "read_receipts"
    case sip
    case message
    case bridgeVersion = "bridge_version"
    case v2Ready = "v2_ready"
    case selectors
    case rpcMethods = "rpc_methods"
  }
}
