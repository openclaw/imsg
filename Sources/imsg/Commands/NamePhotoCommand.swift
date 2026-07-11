import Commander
import Foundation
import IMsgCore

enum NamePhotoCommand {
  static let spec = CommandSpec(
    name: "name-photo",
    abstract: "Inspect or share your Messages Name & Photo",
    discussion: """
      Requires `imsg launch` (SIP disabled, dylib injected). `status` reads
      whether Messages would offer Name & Photo sharing for the chat. `share`
      explicitly sends your personal Name & Photo to every chat participant.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "status|share", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid")
        ]
      )
    ),
    usageExamples: [
      "imsg name-photo status --chat 'iMessage;-;+15551234567'",
      "imsg name-photo share --chat 'iMessage;-;+15551234567'",
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

    let action: BridgeAction
    switch values.argument(0) {
    case "status":
      action = .shouldOfferNicknameSharing
    case "share":
      action = .shareNickname
    default:
      throw ParsedValuesError.invalidOption("action")
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: action,
      params: ["chatGuid": chat],
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      if action == .shareNickname {
        let requested = (data["requested"] as? Bool) ?? false
        return "name-photo: share requested=\(requested)"
      }
      let canInspect = (data["can_inspect_offer"] as? Bool) ?? false
      let canShare = (data["can_share"] as? Bool) ?? false
      let nicknameLoaded = (data["personal_nickname_loaded"] as? Bool) ?? false
      let hasPersonalNickname = (data["has_personal_nickname"] as? Bool) ?? false
      let shouldOffer = (data["should_offer"] as? Bool).map(String.init) ?? "unknown"
      return
        "name-photo: can_inspect_offer=\(canInspect) can_share=\(canShare) "
        + "personal_nickname_loaded=\(nicknameLoaded) "
        + "has_personal_nickname=\(hasPersonalNickname) should_offer=\(shouldOffer)"
    }
  }
}
