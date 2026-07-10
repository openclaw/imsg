import Foundation
import IMsgCore

/// Chat/group lifecycle and management methods. Each handler resolves the
/// caller's chat target (`chat_guid` / `chat_identifier` / `chat_id`) into a
/// chat GUID and then dispatches into the v2 bridge action that the dylib
/// already implements.
extension RPCServer {
  func handleChatsCreate(id: Any?, params: [String: Any]) async throws {
    let addresses = stringArrayParam(params["addresses"])
    guard !addresses.isEmpty else {
      throw RPCError.invalidParams("addresses is required (non-empty array of phone/email)")
    }
    let service = stringParam(params["service"]) ?? "iMessage"
    var bridgeParams: [String: Any] = [
      "addresses": addresses,
      "service": service,
    ]
    if let name = stringParam(params["name"]), !name.isEmpty {
      bridgeParams["displayName"] = name
    }
    if let text = stringParam(params["text"]), !text.isEmpty {
      bridgeParams["message"] = text
    }
    let data = try await invokeBridge(action: .createChat, params: bridgeParams)
    var result: [String: Any] = ["ok": true]
    if let guid = data["chatGuid"] as? String, !guid.isEmpty {
      result["chat_guid"] = guid
    }
    if let messageGUID = data["messageGuid"] as? String, !messageGUID.isEmpty {
      result["message_guid"] = messageGUID
    }
    if let service = data["service"] as? String, !service.isEmpty {
      result["service"] = service
    }
    respond(id: id, result: result)
  }

  func handleChatsDelete(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .deleteChat, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  func handleChatsMarkUnread(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .markChatUnread, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  func handleGroupRename(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let name = stringParam(params["name"]) else {
      throw RPCError.invalidParams("name is required")
    }
    _ = try await invokeBridge(
      action: .setDisplayName,
      params: ["chatGuid": chatGUID, "newName": name]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupSetIcon(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = ["chatGuid": chatGUID]
    if let file = stringParam(params["file"]), !file.isEmpty {
      bridgeParams["filePath"] = (file as NSString).expandingTildeInPath
    }
    _ = try await invokeBridge(action: .updateGroupPhoto, params: bridgeParams)
    respond(id: id, result: ["ok": true])
  }

  func handleGroupAddParticipant(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let address = stringParam(params["address"]), !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }
    _ = try await invokeBridge(
      action: .addParticipant,
      params: ["chatGuid": chatGUID, "address": address]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupRemoveParticipant(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    guard let address = stringParam(params["address"]), !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }
    _ = try await invokeBridge(
      action: .removeParticipant,
      params: ["chatGuid": chatGUID, "address": address]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupLeave(id: Any?, params: [String: Any]) async throws {
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .leaveChat, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  // MARK: - Helpers

  /// Resolve a chat GUID from `chat_guid`, `chat_identifier`, or `chat_id`.
  /// Bridge management actions (rename/leave/etc.) require a real chat GUID;
  /// rejecting up-front gives callers a clearer error than the dylib's
  /// downstream "chat not found".
  func resolveChatGUIDParam(_ params: [String: Any]) async throws -> String {
    let input = ChatTargetInput(
      recipient: "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    if !input.hasChatTarget {
      throw RPCError.invalidParams("chat_guid, chat_identifier, or chat_id is required")
    }
    let resolved = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in RPCError.invalidParams("unknown chat_id \(chatID)") }
    )
    if !resolved.chatGUID.isEmpty {
      return resolved.chatGUID
    }
    if !resolved.chatIdentifier.isEmpty {
      if let info = try store.chatInfo(matchingTarget: resolved.chatIdentifier) {
        if !info.guid.isEmpty { return info.guid }
        if !info.identifier.isEmpty { return info.identifier }
      }
      return resolved.chatIdentifier
    }
    throw RPCError.invalidParams("could not resolve chat GUID for chat target")
  }

  func invokeBridge(
    action: BridgeAction, params: [String: Any]
  ) async throws -> [String: Any] {
    do {
      return try await bridgeInvoker(action, params)
    } catch {
      throw RPCError.internalError(String(describing: error))
    }
  }
}
