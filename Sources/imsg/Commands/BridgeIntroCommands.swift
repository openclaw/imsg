import Commander
import Foundation
import IMsgCore

// MARK: - search

enum SearchCommand {
  static let spec = CommandSpec(
    name: "search",
    abstract: "Search local Messages history",
    discussion: """
      Searches the local chat.db, not the injected bridge. Use --match exact
      for case-insensitive exact text matches; the default is contains.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "query", names: [.long("query")], help: "search query (required)"),
          .make(label: "match", names: [.long("match")], help: "exact|contains (default contains)"),
          .make(label: "limit", names: [.long("limit")], help: "maximum results (default 50)"),
        ]
      )
    ),
    usageExamples: ["imsg search --query 'pizza tonight' --match contains"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    contactResolverFactory: @escaping () async -> any ContactResolving = {
      await ContactResolver.create()
    }
  ) async throws {
    guard let q = values.option("query"), !q.isEmpty else {
      throw ParsedValuesError.missingOption("query")
    }
    let match = values.option("match") ?? "contains"
    guard match == "contains" || match == "exact" else {
      throw ParsedValuesError.invalidOption("match")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 50
    let store = try MessageStore(path: dbPath)
    let messages = try store.searchMessages(query: q, match: match, limit: limit)
    let contacts = await contactResolverFactory()

    if runtime.jsonOutput {
      let cache = ChatCache(store: store)
      for message in messages {
        let payload = try await buildMessagePayload(
          store: store,
          cache: cache,
          message: message,
          includeAttachments: false,
          includeReactions: false,
          contactResolver: contacts
        )
        try JSONLines.printObject(payload)
      }
      return
    }

    for message in messages {
      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      let sender =
        message.isFromMe
        ? message.sender : (contacts.displayName(for: message.sender) ?? message.sender)
      StdoutWriter.writeLine("\(timestamp) [\(direction)] \(sender): \(message.text)")
    }
  }
}

// MARK: - account

enum AccountCommand {
  static let spec = CommandSpec(
    name: "account",
    abstract: "Show the active iMessage account, login, and aliases",
    discussion: """
      The default mode reads the live account via the IMCore bridge (requires
      `imsg launch`, SIP disabled). Use --local for a SIP-free listing of the
      account login(s) recorded in local chat.db history. Local mode reflects
      accounts observed in history rather than the live signed-in account; for
      a single-account Mac these are equivalent.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions(),
        flags: [
          .make(
            label: "local", names: [.long("local")],
            help: "list accounts from local chat.db history (no SIP / bridge required)")
        ]
      )),
    usageExamples: ["imsg account", "imsg account --local"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    localAccounts: @escaping (MessageStore) throws -> [LocalAccount] = { try $0.localAccounts() }
  ) async throws {
    if values.flag("local") {
      try runLocal(
        values: values,
        runtime: runtime,
        storeFactory: storeFactory,
        localAccounts: localAccounts
      )
      return
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .getAccountInfo, params: [:], runtime: runtime
    ) { data in
      let login = (data["login"] as? String) ?? ""
      let aliases = (data["vetted_aliases"] as? [String]) ?? []
      return "account: \(login)\n  aliases: \(aliases.joined(separator: ", "))"
    }
  }

  private static func runLocal(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore,
    localAccounts: (MessageStore) throws -> [LocalAccount]
  ) throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    let accounts = try localAccounts(store)

    if runtime.jsonOutput {
      let payload: [[String: Any]] = accounts.map {
        [
          "login": $0.login,
          "account_id": $0.accountID,
          "chat_count": $0.chatCount,
        ]
      }
      try JSONLines.printObject(["source": "local", "accounts": payload])
    } else {
      if accounts.isEmpty {
        StdoutWriter.writeLine("account: (none found in local history) (source=local)")
      } else {
        StdoutWriter.writeLine("accounts (source=local):")
        for account in accounts {
          let label = account.login.isEmpty ? account.accountID : account.login
          StdoutWriter.writeLine("  \(label) (chats=\(account.chatCount))")
        }
      }
    }
  }
}

// MARK: - whois

enum WhoisCommand {
  static let spec = CommandSpec(
    name: "whois",
    abstract: "Check whether a handle is reachable on iMessage",
    discussion: """
      The default mode performs a live reachability check via the IMCore bridge
      (requires `imsg launch`, SIP disabled). Use --local for a SIP-free check
      that infers the preferred service from local chat.db history. Local mode
      only resolves handles you already have message history with; unknown
      handles report service "unknown".
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "address", names: [.long("address")], help: "phone or email to check"),
          .make(label: "type", names: [.long("type")], help: "phone|email"),
        ],
        flags: [
          .make(
            label: "local", names: [.long("local")],
            help: "infer service from local chat.db history (no SIP / bridge required)")
        ]
      )
    ),
    usageExamples: [
      "imsg whois --address +15551234567 --type phone",
      "imsg whois --address foo@bar.com --type email",
      "imsg whois --address foo@bar.com --local",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    resolveService: @escaping (MessageStore, String) throws -> HandleServiceAvailability = {
      store, handle in
      try store.preferredService(forHandle: handle)
    }
  ) async throws {
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }

    if values.flag("local") {
      try runLocal(
        address: addr,
        values: values,
        runtime: runtime,
        storeFactory: storeFactory,
        resolveService: resolveService
      )
      return
    }

    let aliasType = values.option("type") ?? (addr.contains("@") ? "email" : "phone")
    let params: [String: Any] = [
      "address": addr,
      "aliasType": aliasType,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .checkImessageAvailability, params: params, runtime: runtime
    ) { data in
      let avail = (data["available"] as? Bool) ?? false
      let status = (data["id_status"] as? Int) ?? 0
      return "whois \(addr): \(avail ? "available" : "unavailable") (id_status=\(status))"
    }
  }

  private static func runLocal(
    address: String,
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: (String) throws -> MessageStore,
    resolveService: (MessageStore, String) throws -> HandleServiceAvailability
  ) throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    let availability = try resolveService(store, address)

    let service: String
    let known: Bool
    switch availability {
    case .imessage:
      service = "imessage"
      known = true
    case .sms:
      service = "sms"
      known = true
    case .unknown:
      service = "unknown"
      known = false
    }

    if runtime.jsonOutput {
      try JSONLines.printObject([
        "address": address,
        "service": service,
        "known": known,
        "source": "local",
      ])
    } else {
      StdoutWriter.writeLine("whois \(address): \(service) (source=local, known=\(known))")
    }
  }
}

// MARK: - nickname

enum NicknameCommand {
  static let spec = CommandSpec(
    name: "nickname",
    abstract: "Show contact-card / nickname info for a handle",
    discussion: """
      The default mode reads the contact-card nickname the correspondent shared
      over iMessage via the IMCore bridge (requires `imsg launch`, SIP disabled).

      --local is a SIP-free alternative that returns YOUR local AddressBook
      contact name for the handle. NOTE: this is a different datum — it is your
      own contact label, not the iMessage-shared nickname/photo, which is only
      available through the bridge.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "address", names: [.long("address")], help: "phone or email")
        ],
        flags: [
          .make(
            label: "local", names: [.long("local")],
            help: "return local AddressBook contact name (no SIP; NOT the shared nickname)")
        ]
      )
    ),
    usageExamples: [
      "imsg nickname --address +15551234567",
      "imsg nickname --address +15551234567 --local",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    contactResolverFactory: @escaping (String) async -> any ContactResolving = { region in
      await ContactResolver.create(region: region)
    }
  ) async throws {
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }

    if values.flag("local") {
      let region = values.option("region") ?? "US"
      let contacts = await contactResolverFactory(region)
      let name = contacts.displayName(for: addr)
      if runtime.jsonOutput {
        try JSONLines.printObject([
          "address": addr,
          "local_contact_name": name ?? "",
          "found": name != nil,
          "source": "local-addressbook",
          "contacts_unavailable": contacts.contactsUnavailable,
        ])
      } else {
        StdoutWriter.writeLine(
          "local_contact_name: \(name ?? "(none)") (source=local-addressbook)")
      }
      return
    }

    let params: [String: Any] = ["address": addr]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .getNicknameInfo, params: params, runtime: runtime
    ) { data in
      let has = (data["has_nickname"] as? Bool) ?? false
      let desc = (data["description"] as? String) ?? ""
      return "nickname: \(has ? desc : "(none)")"
    }
  }
}
