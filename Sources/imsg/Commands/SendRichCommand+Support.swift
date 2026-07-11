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
    storeFactory: (String) throws -> MessageStore
  ) async throws -> [String: Any] {
    var enriched = data
    guard !text.isEmpty, data["queued"] as? Bool == true else {
      return enriched
    }

    do {
      let store = try storeFactory(dbPath)
      let chatInfo = try store.chatInfo(matchingTarget: chat)
      let resolvedChatGUID = chatInfo?.guid ?? ""
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
      } else if data["queued"] as? Bool == true {
        enriched.removeValue(forKey: "messageGuid")
      }
    } catch {
      if data["queued"] as? Bool == true {
        enriched.removeValue(forKey: "messageGuid")
      }
    }
    return enriched
  }
}
