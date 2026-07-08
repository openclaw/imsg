import Commander
import Foundation
import IMsgCore

enum ContactCardCommand {
  static let spec = CommandSpec(
    name: "contact-card",
    abstract: "Share or inspect iMessage contact-card sharing for a chat",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). The status action
      reports whether the running Messages private API exposes a known contact
      card sharing selector; share fails closed when it does not.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "share|status", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid")
        ]
      )
    ),
    usageExamples: [
      "imsg contact-card status --chat 'iMessage;-;+15551234567'",
      "imsg contact-card share --chat 'iMessage;-;+15551234567'",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    }
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let action = values.argument(0)
    let bridgeAction: BridgeAction
    switch action {
    case "share":
      bridgeAction = .shareContactCard
    case "status":
      bridgeAction = .contactCardSharingStatus
    default:
      throw ParsedValuesError.invalidOption("action")
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: bridgeAction,
      params: ["chatGuid": chat],
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      if action == "share" {
        return "contact-card: share requested"
      }
      let available = (data["available"] as? Bool) ?? false
      let sharing = (data["should_share"] as? Bool).map { $0 ? "yes" : "no" } ?? "unknown"
      return "contact-card: available=\(available) should_share=\(sharing)"
    }
  }
}
