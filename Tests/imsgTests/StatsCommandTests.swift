import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func statsCommandEmitsOneAggregateObjectAndOmitsUnrequestedMedia() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "timeZone": ["UTC"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await StatsCommand.run(values: values, runtime: runtime)
  }

  #expect(output.split(separator: "\n").count == 1)
  let payload = try statsJSON(from: output)
  #expect(payload["total_messages"] as? Int == 1)
  #expect(payload["sent_messages"] as? Int != nil)
  #expect(payload["received_messages"] as? Int != nil)
  #expect(payload["time_zone"] as? String != nil)
  #expect(payload["media"] == nil)
}

@Test
func statsCommandIncludesMediaOnlyWhenRequested() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment(
    filename: "/tmp/photo.jpg",
    transferName: "photo.jpg",
    uti: "public.jpeg",
    mimeType: "image/jpeg"
  )
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "timeZone": ["UTC"]],
    flags: ["jsonOutput", "media"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await StatsCommand.run(values: values, runtime: runtime)
  }

  let media = try statsJSON(from: output)["media"] as? [String: Any]
  #expect(media?["total_attachments"] as? Int == 1)
  #expect(media?["total_bytes"] as? Int == 10)
}

@Test
func statsCommandRejectsNonnumericChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["not-a-number"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  await #expect(throws: ParsedValuesError.self) {
    try await StatsCommand.run(values: values, runtime: runtime)
  }
}

@Test
func statsCommandPlainOutputIncludesDirectionAndTimeZone() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "timeZone": ["Europe/Vienna"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await StatsCommand.run(values: values, runtime: runtime)
  }

  #expect(output.contains("Messages: 1 ("))
  #expect(output.contains("sent,"))
  #expect(output.contains("received)"))
  #expect(output.contains("Time zone: Europe/Vienna"))
}

@Test
func rpcMessagesStatsReturnsTheCanonicalAggregate() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithAttachment(
    filename: "/tmp/photo.jpg",
    transferName: "photo.jpg",
    uti: "public.jpeg",
    mimeType: "image/jpeg"
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"stats","method":"messages.stats","params":{"chat_id":1,"include_media":true,"time_zone":"UTC"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["total_messages"] as? Int == 1)
  #expect(result?["time_zone"] as? String != nil)
  let media = result?["media"] as? [String: Any]
  #expect(media?["total_attachments"] as? Int == 1)
}

@Test
func rpcMessagesStatsRejectsInvalidParamsWithoutWidening() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bad-type","method":"messages.stats","params":{"chat_id":"all"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"string-id","method":"messages.stats","params":{"chat_id":"1"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"missing","method":"messages.stats","params":{"chat_id":999}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bad-zone","method":"messages.stats","params":{"time_zone":"Not/AZone"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"number-zone","method":"messages.stats","params":{"time_zone":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"number-media","method":"messages.stats","params":{"include_media":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unknown","method":"messages.stats","params":{"chatId":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"array","method":"messages.stats","params":[]}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"null","method":"messages.stats","params":null}"#
  )

  #expect(output.errors.count == 9)
  for response in output.errors {
    let error = response["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
  }
}

@Test
func rpcStatsProposalAliasesAreNotExposed() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"legacy","method":"server.getMessageStats","params":{}}"#
  )

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32601)
}

private func statsJSON(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? "{}"
  let data = Data(line.utf8)
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
