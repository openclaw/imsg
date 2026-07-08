import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func statsCommandRunsWithJsonOutput() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment(
    filename: "/tmp/photo.jpg",
    transferName: "photo.jpg",
    uti: "public.jpeg",
    mimeType: "image/jpeg"
  )
  let values = ParsedValues(
    positional: [],
    options: ["db": [path]],
    flags: ["jsonOutput", "media"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await StatsCommand.run(values: values, runtime: runtime)
  }

  let payload = try statsJSON(from: output)
  #expect(payload["total_messages"] as? Int == 1)
  let chats = payload["chats"] as? [[String: Any]] ?? []
  #expect(chats.first?["chat_id"] as? Int == 1)
  let media = payload["media"] as? [String: Any]
  #expect(media?["total_attachments"] as? Int == 1)
  #expect(media?["total_bytes"] as? Int == 10)
}

@Test
func statsCommandRunsWithPlainOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await StatsCommand.run(values: values, runtime: runtime)
  }

  #expect(output.contains("Messages: 1"))
  #expect(output.contains("By chat:"))
}

@Test
func rpcServerGetMessageStatsReturnsAggregates() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithAttachment(
    filename: "/tmp/photo.jpg",
    transferName: "photo.jpg",
    uti: "public.jpeg",
    mimeType: "image/jpeg"
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"stats","method":"server.getMessageStats","params":{"media":true}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["total_messages"] as? Int == 1)
  let media = result?["media"] as? [String: Any]
  #expect(media?["total_attachments"] as? Int == 1)
}

@Test
func rpcGetMediaStatisticsByChatRequiresChatID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"media","method":"getMediaStatisticsByChat","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32602)
}

private func statsJSON(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? "{}"
  let data = Data(line.utf8)
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
