import Commander
import Foundation
import IMsgCore

enum ICloudCommand {
  static let spec = CommandSpec(
    name: "icloud",
    abstract: "Inspect or start a Messages in iCloud sync",
    discussion: """
      Requires `imsg launch` (SIP disabled, dylib injected). `status` reports
      whether Messages in iCloud is syncing and when it last finished. `sync`
      starts a user-initiated sync and returns immediately; run `status` to
      see when it finishes.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        arguments: [
          .make(label: "action", help: "status|sync", isOptional: false)
        ],
        options: CommandSignatures.baseOptions()
      )
    ),
    usageExamples: [
      "imsg icloud status",
      "imsg icloud sync",
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
    let action: BridgeAction
    switch values.argument(0) {
    case "status":
      action = .getICloudSyncStatus
    case "sync":
      action = .startICloudSync
    default:
      throw ParsedValuesError.invalidOption("action")
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: action,
      params: [:],
      runtime: runtime,
      invokeBridge: invokeBridge
    ) { data in
      let syncing = (data["syncing"] as? Bool) ?? false
      let lastSyncAt = (data["last_sync_at"] as? String) ?? "never"
      let state = "syncing=\(syncing) last_sync_at=\(lastSyncAt)"
      return action == .startICloudSync
        ? "icloud: sync requested \(state)" : "icloud: \(state)"
    }
  }
}
