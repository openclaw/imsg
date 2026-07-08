import Commander
import Foundation
import IMsgCore

enum ChatsCommand {
  static let spec = CommandSpec(
    name: "chats",
    abstract: "List recent conversations",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "limit", names: [.long("limit")], help: "Number of chats to list")
        ],
        flags: [
          .make(
            label: "unread-only", names: [.long("unread-only")],
            help: "Return only chats with unread inbound messages")
        ]
      )
    ),
    usageExamples: [
      "imsg chats --limit 5",
      "imsg chats --limit 5 --json",
      "imsg chats --unread-only --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    contactResolverFactory: @escaping () async -> any ContactResolving = {
      await ContactResolver.create(accessPolicy: .skipIfNotDetermined)
    }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 20
    let unreadOnly = values.flag("unread-only")
    let store = try MessageStore(path: dbPath)
    let chats = try store.listChats(limit: limit, unreadOnly: unreadOnly)
    let contacts = await contactResolverFactory()

    if runtime.jsonOutput {
      for chat in chats {
        let chatInfo = try store.chatInfo(chatID: chat.id)
        let participants = try store.participants(chatID: chat.id)
        let contactName = contactNameForChat(
          chat: chat,
          chatInfo: chatInfo,
          participants: participants,
          contacts: contacts
        )
        try StdoutWriter.writeJSONLine(
          ChatPayload(
            chat: chat,
            chatInfo: chatInfo,
            participants: participants,
            contactName: contactName
          ))
      }
      return
    }

    for chat in chats {
      let last = CLIISO8601.format(chat.lastMessageAt)
      let participants = try store.participants(chatID: chat.id)
      let contactName = contactNameForChat(
        chat: chat,
        chatInfo: nil,
        participants: participants,
        contacts: contacts
      )
      let displayName = contactName ?? chat.name
      StdoutWriter.writeLine("[\(chat.id)] \(displayName) (\(chat.identifier)) last=\(last)")
    }
  }

  private static func contactNameForChat(
    chat: Chat,
    chatInfo: ChatInfo?,
    participants: [String],
    contacts: any ContactResolving
  ) -> String? {
    let identifier = chatInfo?.identifier ?? chat.identifier
    let guid = chatInfo?.guid ?? ""
    guard !isGroupHandle(identifier: identifier, guid: guid) else { return nil }
    if let name = contacts.displayName(for: identifier) {
      return name
    }
    if participants.count == 1 {
      return contacts.displayName(for: participants[0])
    }
    return nil
  }
}
