import Commander
import Foundation
import IMsgCore

enum StatusCommand {
  static func availableBridgeSendCommands(selectors: [String: Bool]) -> [String] {
    var commands = ["send-rich", "send-multipart", "send-attachment"]
    if selectors["stickerSend"] == true { commands.append("send-sticker") }
    commands.append("tapback")
    return commands
  }

  static func advertisedRPCMethods(selectors: [String: Bool]) -> [String] {
    selectors["clientMessageGuidReservation"] == true
      ? kSupportedRPCMethods
      : kSupportedRPCMethods.filter { $0 != "send.tracked" }
  }

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

  static func run(
    values: ParsedValues, runtime: RuntimeOptions,
    availability: (available: Bool, message: String) = IMCoreBridge.shared.checkAvailability(),
    probe: () async throws -> [String: Any] = {
      try await IMsgBridgeClient.shared.invoke(action: .status, params: [:], timeout: 3.0)
    }
  ) async throws {
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
    var helperVersion: String?
    var helperResponded = false
    var unresponsiveMessage: String?
    if availability.available {
      do {
        let data = try await probe()
        helperResponded = true
        bridgeVersion = (data["bridge_version"] as? Int) ?? 0
        v2Ready = (data["v2_ready"] as? Bool) ?? false
        helperVersion = data["helper_version"] as? String
        if let raw = data["selectors"] as? [String: Bool] { selectors = raw }
      } catch IMsgBridgeError.timeout {
        unresponsiveMessage = """
          The IMCore bridge is not responding.
          Messages.app may be running with a stale or hung helper.
          Re-inject it with `imsg launch`.
          """
      } catch {
        // Reply errors and prepublication failures do not establish a hung helper.
      }
    }

    let advancedAvailable = availability.available && unresponsiveMessage == nil

    // A dylib injected by an older release keeps answering pings forever
    // (Messages.app stays up for weeks), so a CLI upgrade alone does not
    // update the bridge. Surface the mismatch instead of failing deep inside
    // feature requests with confusing RPC errors.
    let helperVersionMismatch: String? = {
      guard helperResponded, helperVersion != IMsgVersion.current else { return nil }
      guard let helperVersion else {
        return """
          The injected bridge dylib predates release version reporting. Run `imsg launch` \
          to relaunch Messages.app with the current dylib.
          """
      }
      return """
        The injected bridge dylib reports version \(helperVersion), but this CLI is \
        \(IMsgVersion.current). Run `imsg launch` to relaunch Messages.app with the \
        current dylib.
        """
    }()

    if runtime.jsonOutput {
      let payload = StatusPayload(
        version: IMsgVersion.current,
        basicFeatures: true,
        advancedFeatures: advancedAvailable,
        typingIndicators: advancedAvailable,
        readReceipts: advancedAvailable,
        sip: sipStatus,
        message: unresponsiveMessage ?? availability.message,
        bridgeVersion: bridgeVersion,
        v2Ready: v2Ready,
        helperVersion: helperVersion,
        helperVersionMismatch: helperVersionMismatch,
        selectors: selectors,
        rpcMethods: advertisedRPCMethods(selectors: selectors),
        capabilities: EngineCapabilities.current(emojiTapbackSend: selectors["emojiTapbackSend"] == true)
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
      if let unresponsiveMessage {
        StdoutWriter.writeLine("  Unavailable - IMCore bridge is not responding")
        for line in unresponsiveMessage.split(separator: "\n") {
          StdoutWriter.writeLine("  \(line)")
        }
      } else if advancedAvailable {
        StdoutWriter.writeLine("  Available - IMCore bridge connected")
        StdoutWriter.writeLine(
          "  bridge version: v\(bridgeVersion)\(v2Ready ? " (v2 inbox active)" : "")")
        if let helperVersion {
          StdoutWriter.writeLine("  helper dylib version: \(helperVersion)")
        }
        if let mismatch = helperVersionMismatch {
          StdoutWriter.writeLine("")
          StdoutWriter.writeLine("  WARNING: \(mismatch)")
        }
        if !selectors.isEmpty {
          StdoutWriter.writeLine("  selectors:")
          for key in selectors.keys.sorted() {
            let ok = selectors[key] ?? false
            StdoutWriter.writeLine("    \(key): \(ok ? "✓" : "✗")")
          }
        }
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("Available bridge commands:")
        let sendCommands = availableBridgeSendCommands(selectors: selectors)
        StdoutWriter.writeLine("  Send: imsg \(sendCommands.joined(separator: ", "))")
        StdoutWriter.writeLine("  Mutate: imsg edit, unsend, delete-message, notify-anyways")
        StdoutWriter.writeLine(
          "  Chat: imsg chat-create, chat-name, chat-photo, chat-add/remove-member, chat-leave/delete, chat-mark"
        )
        StdoutWriter.writeLine("  Introspect: imsg account, whois, nickname")
        StdoutWriter.writeLine("  Name & Photo: imsg name-photo status|share")
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
  let helperVersion: String?
  let helperVersionMismatch: String?
  let selectors: [String: Bool]
  let rpcMethods: [String]
  let capabilities: EngineCapabilities

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
    case helperVersion = "helper_version"
    case helperVersionMismatch = "helper_version_mismatch"
    case selectors
    case rpcMethods = "rpc_methods"
    case capabilities
  }
}
