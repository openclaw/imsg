import Foundation
import IMsgCore

/// Messages in iCloud sync state, read and started through the injected
/// helper because the CloudKit daemon proxy only answers Messages.app.
extension RPCServer {
  func handleICloudStatus(params: [String: Any], id: Any?) async throws {
    _ = try RPCParameters(params, method: "icloud.status", supportedKeys: [])
    let data = try await invokeBridge(action: .getICloudSyncStatus, params: [:])
    respond(id: id, result: icloudSyncResult(data))
  }

  func handleICloudSync(params: [String: Any], id: Any?) async throws {
    _ = try RPCParameters(params, method: "icloud.sync", supportedKeys: [])
    let data = try await invokeBridge(action: .startICloudSync, params: [:])
    var result = icloudSyncResult(data)
    result["requested"] = true
    respond(id: id, result: result)
  }

  private func icloudSyncResult(_ data: [String: Any]) -> [String: Any] {
    [
      "ok": true,
      "syncing": data["syncing"] as? Bool ?? false,
      "last_sync_at": data["last_sync_at"] as? String ?? NSNull(),
    ]
  }
}
