import Foundation

/// Wire-level constants and helpers for the v2 imsg ↔ dylib bridge protocol.
///
/// v1 (legacy) used a single overwriting `.imsg-command.json` file with a 100ms
/// polling loop in the dylib. That model races when two CLI invocations write
/// concurrently. v2 uses a per-request queue directory: callers atomically
/// rename `<uuid>.tmp` → `<uuid>.json` into `.imsg-rpc/in/`, the dylib
/// processes each file once and writes the matching response into
/// `.imsg-rpc/out/<uuid>.json`.
public enum IMsgBridgeProtocol {
  /// Current envelope version. Bump when the on-wire shape changes.
  public static let version: Int = 2

  /// Subdirectory under the Messages.app sandbox container holding RPC files.
  public static let rpcDirectoryName: String = ".imsg-rpc"
  public static let inboxDirectoryName: String = "in"
  public static let outboxDirectoryName: String = "out"

  /// Inbound async event log written by the dylib (typing, alias-changes, …).
  public static let eventsFileName: String = ".imsg-events.jsonl"
  public static let rotatedEventsFileName: String = ".imsg-events.jsonl.1"
  public static let eventsRotationBytes: Int = 1 * 1024 * 1024

  /// Default per-request timeout for synchronous non-send RPC waits.
  public static let defaultResponseTimeout: TimeInterval = 10.0

  /// Default timeout for send-style bridge waits. macOS 26 private sends can
  /// stall for well over the probe window before Messages.app returns.
  public static let defaultSendResponseTimeout: TimeInterval = 150.0

  public static func defaultResponseTimeout(for action: BridgeAction) -> TimeInterval {
    switch action {
    case .sendMessage, .sendMultipart, .sendAttachment, .sendPoll, .sendReaction,
      .createChat:
      return defaultSendResponseTimeout
    default:
      return defaultResponseTimeout
    }
  }
}

/// All action verbs exposed by the v2 bridge. Names match the BlueBubbles
/// reference vocabulary so traffic shape stays familiar, but each handler is a
/// local rewrite inside `Sources/IMsgHelper/IMsgInjected.m`.
public enum BridgeAction: String, Sendable, CaseIterable {
  // Liveness
  case ping
  case status
  case listChats = "list_chats"

  // Typing
  case typing  // legacy compound: { handle, typing: bool }
  case startTyping = "start-typing"
  case stopTyping = "stop-typing"
  case checkTypingStatus = "check-typing-status"

  // Read
  case read  // legacy
  case markChatRead = "mark-chat-read"
  case markChatUnread = "mark-chat-unread"

  // Send
  case sendMessage = "send-message"
  case sendMultipart = "send-multipart"
  case sendAttachment = "send-attachment"
  case sendPoll = "send-poll"
  case sendReaction = "send-reaction"
  case notifyAnyways = "notify-anyways"

  // Mutate
  case editMessage = "edit-message"
  case unsendMessage = "unsend-message"
  case deleteMessage = "delete-message"

  // Chat management
  case addParticipant = "add-participant"
  case removeParticipant = "remove-participant"
  case setDisplayName = "set-display-name"
  case updateGroupPhoto = "update-group-photo"
  case leaveChat = "leave-chat"
  case deleteChat = "delete-chat"
  case createChat = "create-chat"

  // Introspection
  case searchMessages = "search-messages"
  case getAccountInfo = "get-account-info"
  case getNicknameInfo = "get-nickname-info"
  case checkImessageAvailability = "check-imessage-availability"
  case downloadPurgedAttachment = "download-purged-attachment"
}

/// Reaction kinds (BlueBubbles vocabulary) → IMAssociatedMessageType integers.
///
/// Constants are stable across macOS 11–15. Add 1000 to the kind id to send a
/// removal (e.g. `love` → 2000, `remove-love` → 3000).
public enum BridgeReactionKind: String, Sendable, CaseIterable {
  case love
  case like
  case dislike
  case laugh
  case emphasize
  case question
  case removeLove = "remove-love"
  case removeLike = "remove-like"
  case removeDislike = "remove-dislike"
  case removeLaugh = "remove-laugh"
  case removeEmphasize = "remove-emphasize"
  case removeQuestion = "remove-question"

  public var associatedMessageType: Int {
    switch self {
    case .love: return 2000
    case .like: return 2001
    case .dislike: return 2002
    case .laugh: return 2003
    case .emphasize: return 2004
    case .question: return 2005
    case .removeLove: return 3000
    case .removeLike: return 3001
    case .removeDislike: return 3002
    case .removeLaugh: return 3003
    case .removeEmphasize: return 3004
    case .removeQuestion: return 3005
    }
  }
}

/// Errors surfaced by `IMsgBridgeClient` and adjacent helpers.
public enum IMsgBridgeError: Error, CustomStringConvertible, Equatable {
  case bridgeNotReady(String)
  case timeout(action: String)
  case malformedResponse(String)
  case dylibReturnedError(String)
  case ioError(String)

  public var description: String {
    switch self {
    case .bridgeNotReady(let detail): return "imsg bridge not ready: \(detail)"
    case .timeout(let action): return "Timed out waiting for response to '\(action)'"
    case .malformedResponse(let detail): return "Malformed bridge response: \(detail)"
    case .dylibReturnedError(let msg): return "Dylib error: \(msg)"
    case .ioError(let detail): return "Bridge IO error: \(detail)"
    }
  }
}

/// Decoded shape of a v2 bridge response.
///
/// The dylib always writes `{"v":2,"id":"<uuid>","success":<bool>,...}`. On
/// success, action-specific fields land under `data` (or directly at the top
/// level for handlers that haven't been migrated yet). On failure, `error`
/// holds a human-readable string.
public struct BridgeResponse {
  public let id: String
  public let success: Bool
  public let data: [String: Any]
  public let error: String?

  public init(id: String, success: Bool, data: [String: Any], error: String?) {
    self.id = id
    self.success = success
    self.data = data
    self.error = error
  }

  /// Parse a JSON response object into a `BridgeResponse`. Tolerates v1 shape
  /// (no `v` field, integer `id`) so the legacy single-file IPC keeps working.
  public static func parse(_ raw: [String: Any]) throws -> BridgeResponse {
    let id: String
    if let s = raw["id"] as? String {
      id = s
    } else if let i = raw["id"] as? Int {
      id = String(i)
    } else if let d = raw["id"] as? Double {
      id = String(Int(d))
    } else {
      id = ""
    }

    let success = (raw["success"] as? Bool) ?? false
    let error = raw["error"] as? String

    var data: [String: Any]
    if let d = raw["data"] as? [String: Any] {
      data = d
    } else {
      data = raw
      for stripped in ["v", "id", "success", "error", "timestamp"] {
        data.removeValue(forKey: stripped)
      }
    }

    return BridgeResponse(id: id, success: success, data: data, error: error)
  }
}
