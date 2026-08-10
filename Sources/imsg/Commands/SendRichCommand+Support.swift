import Commander
import Foundation
import IMsgCore

extension SendRichCommand {
  static func validateRichLinkOptions(values: ParsedValues, chat: String) throws {
    if chat.lowercased().hasPrefix("sms;") {
      throw ParsedValuesError.invalidOption("chat")
    }
    let incompatibleOptions = [
      "text", "file", "effect", "subject", "replyTo", "part", "format", "formatFile",
    ]
    for option in incompatibleOptions where values.option(option) != nil {
      throw ParsedValuesError.invalidOption(option)
    }
    if values.flag("noDDScan") {
      throw ParsedValuesError.invalidOption("no-dd-scan")
    }
  }

  static func validateRichLinkChat(
    _ chat: String,
    dbPath: String,
    storeFactory: (String) throws -> MessageStore
  ) throws {
    let store = try storeFactory(dbPath)
    guard let chatInfo = try store.chatInfo(matchingExactTarget: chat) else {
      throw ParsedValuesError.invalidOption("chat")
    }
    let service = chatInfo.service.lowercased()
    guard service == "imessage" || service == "imessagelite" else {
      throw ParsedValuesError.invalidOption("chat")
    }
  }

  static func enrichedSentMessageResponse(
    _ data: [String: Any],
    chat: String,
    text: String,
    dbPath: String,
    sentAt: Date,
    resolveSentMessage:
      @escaping (
        MessageStore,
        MessageSendOptions,
        Int64?,
        Date
      ) async throws -> Message?,
    storeFactory: (String) throws -> MessageStore,
    resolveRow: Bool = false
  ) async throws -> [String: Any] {
    let store = try? storeFactory(dbPath)
    let chatInfo = try? store?.chatInfo(matchingTarget: chat)
    return await enrichedSentMessageResponse(
      data,
      chat: chat,
      text: text,
      sentAt: sentAt,
      store: store,
      chatInfo: chatInfo,
      resolveSentMessage: resolveSentMessage,
      resolveRow: resolveRow
    )
  }

  static func enrichedSentMessageResponse(
    _ data: [String: Any],
    chat: String,
    text: String,
    sentAt: Date,
    store: MessageStore?,
    chatInfo: ChatInfo?,
    resolveSentMessage:
      @escaping (
        MessageStore,
        MessageSendOptions,
        Int64?,
        Date
      ) async throws -> Message?,
    resolveRow: Bool = false
  ) async -> [String: Any] {
    var enriched = data
    let bridgeGUID = (data["messageGuid"] as? String) ?? ""
    let resolvedChatGUID = chatInfo?.guid ?? ""
    let responseChatGUID =
      ((data["chatGuid"] as? String).flatMap { $0.isEmpty ? nil : $0 })
      ?? (!resolvedChatGUID.isEmpty ? resolvedChatGUID : chat)
    if !responseChatGUID.isEmpty {
      enriched["chat_guid"] = responseChatGUID
    }

    let queued = data["queued"] as? Bool == true
    guard !text.isEmpty, queued || resolveRow, let store else {
      if queued {
        enriched.removeValue(forKey: "messageGuid")
      } else if !bridgeGUID.isEmpty {
        enriched["guid"] = bridgeGUID
        enriched["message_id"] = bridgeGUID
      }
      return enriched
    }

    do {
      let options = MessageSendOptions(
        recipient: "",
        text: text,
        service: .auto,
        chatIdentifier: chatInfo?.identifier ?? "",
        chatGUID: resolvedChatGUID.isEmpty ? chat : resolvedChatGUID
      )
      if let sentMessage = try await resolveSentMessage(store, options, chatInfo?.id, sentAt) {
        enriched["id"] = sentMessage.rowID
        if !sentMessage.guid.isEmpty {
          enriched["guid"] = sentMessage.guid
          enriched["message_id"] = sentMessage.guid
          enriched["messageGuid"] = sentMessage.guid
        }
      } else if queued {
        enriched.removeValue(forKey: "messageGuid")
      }
    } catch {
      if queued {
        enriched.removeValue(forKey: "messageGuid")
      }
    }
    if enriched["guid"] == nil, !queued, !bridgeGUID.isEmpty {
      enriched["guid"] = bridgeGUID
      enriched["message_id"] = bridgeGUID
    }
    return enriched
  }
}
