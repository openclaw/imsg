import Commander
import Foundation
import IMsgCore

enum RpcCommand {
  /// Contacts policy for RPC startup.
  ///
  /// Headless RPC (stdin not a TTY: LaunchAgent, pipes, automation) must not
  /// block on a Contacts prompt that will never resolve while authorization
  /// remains `.notDetermined`. Interactive terminals keep the prompt-capable
  /// path so Contacts-backed name resolution still works.
  static var startupContactsAccessPolicy: ContactsAccessPolicy {
    contactsAccessPolicy(stdinIsTTY: ContactsAccessPolicy.stdinIsTTY)
  }

  /// Pure policy helper for tests and callers that already know interactivity.
  static func contactsAccessPolicy(stdinIsTTY: Bool) -> ContactsAccessPolicy {
    .forStdin(isTTY: stdinIsTTY)
  }

  static let spec = CommandSpec(
    name: "rpc",
    abstract: "Run JSON-RPC over stdin/stdout",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(options: CommandSignatures.baseOptions())
    ),
    usageExamples: [
      "imsg rpc",
      "imsg rpc --db ~/Library/Messages/chat.db",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    contactResolverFactory: @escaping () async -> any ContactResolving = {
      await ContactResolver.create(accessPolicy: startupContactsAccessPolicy)
    }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let contacts = await contactResolverFactory()
    let server = RPCServer(
      databasePath: dbPath,
      verbose: runtime.verbose,
      contactResolver: contacts
    )
    try await server.run()
  }
}
