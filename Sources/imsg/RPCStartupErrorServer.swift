import Foundation

/// Keeps `imsg rpc` stdout machine-parseable even when startup prerequisites
/// such as Full Disk Access are missing before the real RPC server can open.
final class RPCStartupErrorServer {
  private let errorMessage: String
  private let output: RPCOutput

  init(error: Error, output: RPCOutput = RPCWriter()) {
    self.errorMessage = String(describing: error)
    self.output = output
  }

  func run() async {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLineForTesting(trimmed)
    }
  }

  func handleLineForTesting(_ line: String) async {
    switch RPCRequestParser.parse(line) {
    case .success(let request):
      if !request.isNotification {
        output.sendError(id: request.id, error: RPCError.internalError(errorMessage))
      }
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
    }
  }
}
