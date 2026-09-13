import Foundation
import IMsgCore

extension RPCServer {
  func handleTyping(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget, ["to", "typing", "service"])
    let params = try RPCParameters(params, method: "typing", supportedKeys: supportedKeys)
    let isTyping = try params.boolean("typing") ?? true
    let serviceRaw = try params.string("service") ?? "imessage"
    let input = try params.recipientOrChatTarget()
    let database: RPCDatabaseResources?
    if input.chatID != nil {
      database = try await databaseResources.require()
    } else {
      database = await databaseResources.available()
    }
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try database?.store.chatInfo(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let identifier: String
    if let preferred = resolvedTarget.preferredIdentifier {
      identifier = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      do {
        guard let service = MessageService(rawValue: serviceRaw.lowercased()) else {
          throw RPCError.invalidParams(serviceRaw)
        }
        if let database,
          let info = try ChatTargetResolver.existingDirectChat(
            store: database.store, recipient: input.recipient, service: service),
          let preferred = bridgeChatGUID(resolvedTarget: nil, directChatInfo: info)
        {
          identifier = preferred
        } else {
          identifier = try ChatTargetResolver.directTypingIdentifier(
            recipient: input.recipient,
            serviceRaw: serviceRaw,
            invalidServiceError: { RPCError.invalidParams($0) }
          )
        }
      } catch let err as RPCError {
        throw err
      }
    }
    if isTyping {
      try startTyping(identifier)
    } else {
      try stopTyping(identifier)
    }
    respond(id: id, result: ["ok": true])
  }

  /// `read` — mark all messages in a chat as read on this device, which also
  /// fires a read-receipt to the sender if the chat has receipts enabled.
  func handleRead(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(RPCParameterKeys.chatTarget, ["to"])
    let params = try RPCParameters(params, method: "read", supportedKeys: supportedKeys)
    let input = try params.recipientOrChatTarget()
    let database: RPCDatabaseResources?
    if input.chatID != nil {
      database = try await databaseResources.require()
    } else {
      database = await databaseResources.available()
    }
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try database?.store.chatInfo(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let handle: String
    if let preferred = resolvedTarget.preferredIdentifier {
      handle = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      handle = input.recipient
    }
    try await markAsRead(handle)
    respond(id: id, result: ["ok": true])
  }

}
