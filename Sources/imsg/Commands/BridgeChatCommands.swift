import Commander
import Foundation
import IMsgCore

// MARK: - chat-create

enum ChatCreateCommand {
  static let spec = CommandSpec(
    name: "chat-create",
    abstract: "Create a new chat (1:1 or group)",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Vends handles for
      each address, including previously uncontacted recipients, through the
      active iMessage account. Every recipient must pass an IDS availability
      check before the chat is created. Optionally sets a display name and sends an
      initial message. Chat creation is currently iMessage-only; use
      `imsg send --service sms` for SMS sends.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "addresses", names: [.long("addresses")],
            help: "comma-separated handles (phone or email)"),
          .make(label: "name", names: [.long("name")], help: "group display name"),
          .make(label: "text", names: [.long("text")], help: "initial message body"),
          .make(
            label: "service", names: [.long("service")], help: "iMessage (default)"),
        ]
      )
    ),
    usageExamples: [
      "imsg chat-create --addresses '+15551234567,+15559876543' --name 'Crew' --text 'gm'"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let raw = values.option("addresses"), !raw.isEmpty else {
      throw ParsedValuesError.missingOption("addresses")
    }
    let addresses = raw.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    .filter { !$0.isEmpty }
    guard !addresses.isEmpty else { throw ParsedValuesError.invalidOption("addresses") }

    let service = values.option("service") ?? "iMessage"
    guard service.caseInsensitiveCompare("iMessage") == .orderedSame else {
      throw IMsgError.unsupportedService(service)
    }

    var params: [String: Any] = [
      "addresses": addresses,
      "service": "iMessage",
    ]
    if let text = values.option("text"), !text.isEmpty { params["message"] = text }
    if let name = values.option("name"), !name.isEmpty { params["displayName"] = name }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .createChat, params: params, runtime: runtime
    ) { data in
      let guid = (data["chatGuid"] as? String) ?? ""
      return "chat-create: created (guid=\(guid))"
    }
  }
}

// MARK: - chat-name

enum ChatNameCommand {
  static let spec = CommandSpec(
    name: "chat-name",
    abstract: "Set a chat's display name",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "name", names: [.long("name")], help: "new display name"),
        ]
      )
    ),
    usageExamples: ["imsg chat-name --chat 'iMessage;+;chat0000' --name 'New Name'"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let name = values.option("name") else {
      throw ParsedValuesError.missingOption("name")
    }
    let params: [String: Any] = ["chatGuid": chat, "newName": name]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .setDisplayName, params: params, runtime: runtime
    ) { _ in "chat-name: set" }
  }
}

// MARK: - chat-photo

enum ChatPhotoCommand {
  static let spec = CommandSpec(
    name: "chat-photo",
    abstract: "Set or clear a group chat photo",
    discussion: "Omit --file to clear the existing photo.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "path to image (omit to clear)"),
        ]
      )
    ),
    usageExamples: ["imsg chat-photo --chat 'iMessage;+;chat0000' --file ~/Downloads/g.jpg"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    var params: [String: Any] = ["chatGuid": chat]
    if let file = values.option("file"), !file.isEmpty {
      params["filePath"] = (file as NSString).expandingTildeInPath
    }
    _ = try await BridgeOutput.invokeAndEmit(
      action: .updateGroupPhoto, params: params, runtime: runtime
    ) { _ in "chat-photo: updated" }
  }
}

// MARK: - chat-add-member / chat-remove-member

enum ChatAddMemberCommand {
  static let spec = CommandSpec(
    name: "chat-add-member",
    abstract: "Add a participant to a group chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "address", names: [.long("address")], help: "phone or email to add"),
        ]
      )
    ),
    usageExamples: ["imsg chat-add-member --chat 'iMessage;+;chat0000' --address +15551234567"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }
    let params: [String: Any] = ["chatGuid": chat, "address": addr]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .addParticipant, params: params, runtime: runtime
    ) { _ in "chat-add-member: added" }
  }
}

enum ChatRemoveMemberCommand {
  static let spec = CommandSpec(
    name: "chat-remove-member",
    abstract: "Remove a participant from a group chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "address", names: [.long("address")], help: "phone or email to remove"),
        ]
      )
    ),
    usageExamples: ["imsg chat-remove-member --chat 'iMessage;+;chat0000' --address +15551234567"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }
    let params: [String: Any] = ["chatGuid": chat, "address": addr]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .removeParticipant, params: params, runtime: runtime
    ) { _ in "chat-remove-member: removed" }
  }
}

// MARK: - chat-leave / chat-delete

enum ChatLeaveCommand {
  static let spec = CommandSpec(
    name: "chat-leave",
    abstract: "Leave a group chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid")
        ]
      )
    ),
    usageExamples: ["imsg chat-leave --chat 'iMessage;+;chat0000'"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let params: [String: Any] = ["chatGuid": chat]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .leaveChat, params: params, runtime: runtime
    ) { _ in "chat-leave: left" }
  }
}

enum ChatDeleteCommand {
  static let spec = CommandSpec(
    name: "chat-delete",
    abstract: "Delete a chat from Messages.app",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid")
        ]
      )
    ),
    usageExamples: ["imsg chat-delete --chat 'iMessage;-;+15551234567'"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let params: [String: Any] = ["chatGuid": chat]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .deleteChat, params: params, runtime: runtime
    ) { _ in "chat-delete: deleted" }
  }
}

// MARK: - chat-mark

enum ChatMarkCommand {
  static let spec = CommandSpec(
    name: "chat-mark",
    abstract: "Mark a chat as read or unread",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid")
        ],
        flags: [
          .make(label: "read", names: [.long("read")], help: "mark as read"),
          .make(label: "unread", names: [.long("unread")], help: "mark as unread"),
        ]
      )
    ),
    usageExamples: [
      "imsg chat-mark --chat ... --read",
      "imsg chat-mark --chat ... --unread",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let read = values.flag("read")
    let unread = values.flag("unread")
    if read && unread {
      throw ParsedValuesError.invalidOption("read")
    }
    let action: BridgeAction = unread ? .markChatUnread : .markChatRead
    let params: [String: Any] = ["chatGuid": chat]
    _ = try await BridgeOutput.invokeAndEmit(
      action: action, params: params, runtime: runtime
    ) { _ in "chat-mark: \(unread ? "unread" : "read")" }
  }
}
