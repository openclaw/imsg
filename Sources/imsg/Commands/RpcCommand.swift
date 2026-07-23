import Commander
import Foundation
import IMsgCore

enum RpcCommand {
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
    ],
    mutation: .read
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store: MessageStore
    do {
      store = try MessageStore(path: dbPath)
    } catch {
      await RPCStartupErrorServer(error: error).run()
      throw CommandOutputEmittedError()
    }
    let contacts = await ContactResolver.create()
    let server = RPCServer(
      store: store,
      verbose: runtime.verbose,
      readOnly: runtime.readOnly,
      redactCodes: runtime.redactCodes,
      contactResolver: contacts
    )
    try await server.run()
  }
}
