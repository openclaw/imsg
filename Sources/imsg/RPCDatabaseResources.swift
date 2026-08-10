import Foundation
import IMsgCore

typealias RPCMessageStoreFactory = @Sendable (String) throws -> MessageStore

struct RPCDatabaseResources: Sendable {
  let store: MessageStore
  let watcher: MessageWatcher

  init(store: MessageStore) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
  }
}

struct RPCDatabaseCapabilities: Sendable, Equatable {
  let unreadState: Bool
  let scheduledMessages: Bool
  let reactions: Bool
  let replyContext: Bool
  let routingMetadata: Bool
  let balloonPayloads: Bool

  init(store: MessageStore) {
    self.unreadState = store.supportsUnreadState
    self.scheduledMessages = store.supportsScheduledMessages
    self.reactions = store.supportsReactions
    self.replyContext = store.supportsReplyContext
    self.routingMetadata = store.supportsRoutingMetadata
    self.balloonPayloads = store.supportsBalloonPayloads
  }

  var dictionary: [String: Any] {
    [
      "unread_state": unreadState,
      "scheduled_messages": scheduledMessages,
      "reactions": reactions,
      "reply_context": replyContext,
      "routing_metadata": routingMetadata,
      "balloon_payloads": balloonPayloads,
    ]
  }
}

struct RPCDatabaseSnapshot: Sendable {
  let path: String
  let resources: RPCDatabaseResources?
  let error: String?

  var capabilities: RPCDatabaseCapabilities? {
    resources.map { RPCDatabaseCapabilities(store: $0.store) }
  }

  var dictionary: [String: Any] {
    var result: [String: Any] = [
      "path": path,
      "ready": resources != nil,
    ]
    if let capabilities {
      result["features"] = capabilities.dictionary
    } else if let error {
      result["error"] = error
    }
    return result
  }
}

/// Owns the optional RPC database bundle. Failed opens are deliberately not cached as terminal:
/// every database-backed request and every status snapshot gets another chance to recover.
actor RPCDatabaseResourceOwner {
  nonisolated let path: String

  private let factory: RPCMessageStoreFactory
  private var readyResources: RPCDatabaseResources?
  private var lastOpenError: String?

  init(path: String, factory: @escaping RPCMessageStoreFactory) {
    self.path = (path as NSString).expandingTildeInPath
    self.factory = factory
  }

  init(store: MessageStore) {
    self.path = store.path
    self.factory = { _ in store }
    self.readyResources = RPCDatabaseResources(store: store)
  }

  func require() throws -> RPCDatabaseResources {
    if let readyResources { return readyResources }
    do {
      let resources = RPCDatabaseResources(store: try factory(path))
      readyResources = resources
      lastOpenError = nil
      return resources
    } catch {
      let detail = Self.actionableError(path: path)
      lastOpenError = detail
      throw RPCError.databaseUnavailable(path: path, detail: detail)
    }
  }

  func available() -> RPCDatabaseResources? {
    try? require()
  }

  func snapshot() -> RPCDatabaseSnapshot {
    _ = try? require()
    return RPCDatabaseSnapshot(
      path: path,
      resources: readyResources,
      error: readyResources == nil ? (lastOpenError ?? Self.actionableError(path: path)) : nil
    )
  }

  private static func actionableError(path: String) -> String {
    if !FileManager.default.fileExists(atPath: path) {
      return
        "The configured Messages database does not exist. Create or copy chat.db at this path, then retry."
    }
    return
      "The configured Messages database could not be opened read-only. "
      + "Verify the path and grant Full Disk Access to the supervising process, then retry."
  }
}
