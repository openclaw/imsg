import Foundation
import IMsgCore

/// The JSON-RPC server behind `imsg rpc`, for a host that runs it in process.
///
/// It answers the same methods with the same payloads as the command, which is itself a thin
/// wrapper over this type. Requests are scheduled exactly as on standard input: reads run
/// concurrently, mutations run one at a time, and the server drains when the input ends.
public final class IMsgRPCServer: Sendable {
  let server: RPCServer

  public init(
    databasePath: String = MessageStore.defaultPath,
    verbose: Bool = false,
    output: any RPCOutput = RPCWriter(),
    contactResolver: any ContactResolving = NoOpContactResolver()
  ) {
    self.server = RPCServer(
      databasePath: databasePath,
      verbose: verbose,
      output: output,
      contactResolver: contactResolver
    )
  }

  /// Serves newline-delimited requests from standard input until it closes.
  public func runStandardInput() async throws {
    try await server.run()
  }

  /// Serves requests from `lines`, one JSON-RPC request per element, until the stream ends.
  public func run(lines: AsyncThrowingStream<String, Error>) async throws {
    try await server.run(lines: lines)
  }
}
