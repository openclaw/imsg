import Foundation
import IMsgCore

/// Chat/group lifecycle and management methods. Each handler resolves the
/// caller's chat target (`chat_guid` / `chat_identifier` / `chat_id`) into a
/// chat GUID and then dispatches into the v2 bridge action that the dylib
/// already implements.
extension RPCServer {
  func handleChatsCreate(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "chats.create",
      supportedKeys: ["addresses", "service", "name", "text"]
    )
    let addresses = (try params.stringArray("addresses") ?? [])
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !addresses.isEmpty else {
      throw RPCError.invalidParams("addresses is required (non-empty array of phone/email)")
    }
    let service = try params.string("service") ?? "iMessage"
    guard service.caseInsensitiveCompare("iMessage") == .orderedSame else {
      throw RPCError.invalidParams("service must be iMessage")
    }
    var bridgeParams: [String: Any] = [
      "addresses": addresses,
      "service": "iMessage",
    ]
    if let name = try params.string("name"), !name.isEmpty {
      bridgeParams["displayName"] = name
    }
    if let text = try params.string("text"), !text.isEmpty {
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
    let params = try RPCParameters(
      params, method: "chats.delete", supportedKeys: RPCParameterKeys.chatTarget)
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .deleteChat, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  func handleChatsMarkUnread(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params, method: "chats.markUnread", supportedKeys: RPCParameterKeys.chatTarget)
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .markChatUnread, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  func handleGroupRename(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "group.rename",
      supportedKeys: RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["name"])
    )
    guard let name = try params.string("name") else {
      throw RPCError.invalidParams("name is required")
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(
      action: .setDisplayName,
      params: ["chatGuid": chatGUID, "newName": name]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupSetIcon(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "group.setIcon",
      supportedKeys: RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["file"])
    )
    let file = try params.string("file")
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = ["chatGuid": chatGUID]
    if let file, !file.isEmpty {
      bridgeParams["filePath"] = (file as NSString).expandingTildeInPath
    }
    _ = try await invokeBridge(action: .updateGroupPhoto, params: bridgeParams)
    respond(id: id, result: ["ok": true])
  }

  func handleGroupAddParticipant(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "group.addParticipant",
      supportedKeys: RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["address"])
    )
    guard let address = try params.string("address"), !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(
      action: .addParticipant,
      params: ["chatGuid": chatGUID, "address": address]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupRemoveParticipant(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "group.removeParticipant",
      supportedKeys: RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["address"])
    )
    guard let address = try params.string("address"), !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(
      action: .removeParticipant,
      params: ["chatGuid": chatGUID, "address": address]
    )
    respond(id: id, result: ["ok": true])
  }

  func handleGroupLeave(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params, method: "group.leave", supportedKeys: RPCParameterKeys.chatTarget)
    let chatGUID = try await resolveChatGUIDParam(params)
    _ = try await invokeBridge(action: .leaveChat, params: ["chatGuid": chatGUID])
    respond(id: id, result: ["ok": true])
  }

  // MARK: - Helpers

  /// Resolve a chat GUID from `chat_guid`, `chat_identifier`, or `chat_id`.
  /// Bridge management actions (rename/leave/etc.) require a real chat GUID;
  /// rejecting up-front gives callers a clearer error than the dylib's
  /// downstream "chat not found".
  func resolveChatGUIDParam(
    _ params: RPCParameters,
    preferredServices: [String] = []
  ) async throws -> String {
    let input = try params.chatTarget()
    let resolved = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in RPCError.invalidParams("unknown chat_id \(chatID)") }
    )
    if !resolved.chatGUID.isEmpty {
      return resolved.chatGUID
    }
    if !resolved.chatIdentifier.isEmpty {
      if let info = try store.chatInfo(
        matchingTarget: resolved.chatIdentifier,
        preferredServices: preferredServices
      ) {
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
