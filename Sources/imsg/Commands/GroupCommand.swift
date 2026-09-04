import Commander
import Foundation
import IMsgCore

enum GroupCommand {
  static let spec = CommandSpec(
    name: "group",
    abstract: "Show chat identity and participants for a chat id",
    discussion: "Prints chat identifier, guid, display name, service, group flag, "
      + "and participants for a given chat rowid. Works for direct chats too.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid from 'imsg chats'")
        ]
      )
    ),
    usageExamples: [
      "imsg group --chat-id 1",
      "imsg group --chat-id 1 --json",
    ]
  ) { values, runtime in
    guard let chatID = try values.optionChatID() else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    guard let info = try store.chatInfo(chatID: chatID) else {
      throw IMsgError.chatNotFound(chatID: chatID)
    }
    let participants = try store.participants(chatID: chatID)

    if runtime.jsonOutput {
      try StdoutWriter.writeJSONLine(GroupPayload(chatInfo: info, participants: participants))
      return
    }

    StdoutWriter.writeLine("id: \(info.id)")
    StdoutWriter.writeLine("identifier: \(info.identifier)")
    StdoutWriter.writeLine("guid: \(info.guid)")
    StdoutWriter.writeLine("name: \(info.name)")
    StdoutWriter.writeLine("service: \(info.service)")
    if let accountID = info.accountID {
      StdoutWriter.writeLine("account_id: \(accountID)")
    }
    if let accountLogin = info.accountLogin {
      StdoutWriter.writeLine("account_login: \(accountLogin)")
    }
    if let lastAddressedHandle = info.lastAddressedHandle {
      StdoutWriter.writeLine("last_addressed_handle: \(lastAddressedHandle)")
    }
    let isGroup = isGroupHandle(identifier: info.identifier, guid: info.guid)
    StdoutWriter.writeLine("is_group: \(isGroup)")
    if participants.isEmpty {
      StdoutWriter.writeLine("participants: (none)")
    } else {
      StdoutWriter.writeLine("participants:")
      for handle in participants {
        StdoutWriter.writeLine("  - \(handle)")
      }
    }
  }
}
