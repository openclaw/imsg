import Commander
import Foundation
import IMsgCore

enum NamePhotoCommand {
  static let spec = CommandSpec(
    name: "name-photo",
    abstract: "Inspect, share, or set your Messages Name & Photo",
    discussion: """
      Requires `imsg launch` (SIP disabled, dylib injected). `status` reads
      whether Messages would offer Name & Photo sharing for the chat. `share`
      explicitly sends your personal Name & Photo to every chat participant.
      `set` replaces the personal Name & Photo itself, and `--sharing on|off`
      also turns Name & Photo Sharing on or off.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "status|share|set", isOptional: false)
        ],
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid (status, share)"),
          .make(label: "firstName", names: [.long("first-name")], help: "first name (set)"),
          .make(label: "lastName", names: [.long("last-name")], help: "last name (set)"),
          .make(label: "photo", names: [.long("photo")], help: "image file to use as photo (set)"),
          .make(
            label: "sharing", names: [.long("sharing")],
            help: "turn Name & Photo Sharing on|off (set)"),
        ]
      )
    ),
    usageExamples: [
      "imsg name-photo status --chat 'iMessage;-;+15551234567'",
      "imsg name-photo share --chat 'iMessage;-;+15551234567'",
      "imsg name-photo set --first-name Ada --photo ~/Pictures/ada.jpg --sharing on",
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
    },
    stagePhoto: @escaping (String) throws -> String = MessageSender.stageAttachmentForMessagesApp
  ) async throws {
    let action: BridgeAction
    switch values.argument(0) {
    case "status":
      action = .shouldOfferNicknameSharing
    case "share":
      action = .shareNickname
    case "set":
      try await runSet(
        values: values, runtime: runtime, invokeBridge: invokeBridge, stagePhoto: stagePhoto)
      return
    default:
      throw ParsedValuesError.invalidOption("action")
    }
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
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

  /// Stages the photo where Messages' transfer agent can read it, then asks
  /// the bridge to replace the personal Name & Photo.
  private static func runSet(
    values: ParsedValues,
    runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any],
    stagePhoto: (String) throws -> String
  ) async throws {
    guard values.option("chat") == nil else {
      throw ParsedValuesError.invalidOption("chat")
    }
    guard let firstName = values.option("firstName"), !firstName.isEmpty else {
      throw ParsedValuesError.missingOption("first-name")
    }
    var params: [String: Any] = ["firstName": firstName]
    if let lastName = values.option("lastName") {
      params["lastName"] = lastName
    }
    if let sharing = values.option("sharing") {
      switch sharing {
      case "on": params["sharingEnabled"] = true
      case "off": params["sharingEnabled"] = false
      default: throw ParsedValuesError.invalidOption("sharing")
      }
    }
    if let photo = values.option("photo"), photo.isEmpty {
      throw ParsedValuesError.invalidOption("photo")
    }
    try await requireSetCapability(invokeBridge: invokeBridge)
    if let photo = values.option("photo") {
      params["photoPath"] = try stagePhoto((photo as NSString).expandingTildeInPath)
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .setPersonalNickname,
      params: params,
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      let stored = (data["stored"] as? Bool) ?? false
      let hasPhoto = (data["has_photo"] as? Bool) ?? false
      var summary = "name-photo: set stored=\(stored) has_photo=\(hasPhoto)"
      if let sharing = data["sharing_enabled"] as? Bool {
        summary += " sharing_enabled=\(sharing)"
      }
      return summary
    }
  }

  static func requireSetCapability(
    invokeBridge: (BridgeAction, [String: Any]) async throws -> [String: Any]
  ) async throws {
    let status = try await invokeBridge(.status, [:])
    let selectors = status["selectors"] as? [String: Any]
    guard selectors?["namePhotoSet"] as? Bool == true else {
      throw IMsgBridgeError.bridgeNotReady(
        "running bridge does not support setting Name & Photo; restart Messages with the current imsg bridge"
      )
    }
  }
}
