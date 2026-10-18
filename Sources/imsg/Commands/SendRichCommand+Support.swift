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
}
