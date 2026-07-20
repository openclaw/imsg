import Commander
import Foundation
import IMsgCore

enum RpcCommand {
  /// RPC often runs headless (LaunchAgent / automation). Do not block server
  /// startup on a Contacts prompt that may never resolve when authorization is
  /// still `.notDetermined`. Display-name enrichment stays optional.
  static let startupContactsAccessPolicy: ContactsAccessPolicy = .skipIfNotDetermined

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
    let store: MessageStore
    do {
      store = try MessageStore(path: dbPath)
    } catch {
      await RPCStartupErrorServer(error: error).run()
      throw CommandOutputEmittedError()
    }
    let contacts = await contactResolverFactory()
    let server = RPCServer(store: store, verbose: runtime.verbose, contactResolver: contacts)
    try await server.run()
  }
}
