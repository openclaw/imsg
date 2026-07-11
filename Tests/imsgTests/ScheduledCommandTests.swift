import Commander
import Foundation
import Testing

@testable import imsg

@Test
func scheduledCommandEmitsFutureRowsAsNDJSON() async throws {
  let path = try ScheduledCommandTestDatabase.makePath()
  let router = CommandRouter()

  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "scheduled", "list", "--db", path, "--limit", "1", "--json"])
  }

  #expect(status == 0)
  let lines = output.split(separator: "\n")
  #expect(lines.count == 1)
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
  #expect(payload["guid"] as? String == "scheduled-one")
  #expect(payload["chat_id"] as? Int == 1)
  #expect(payload["scheduled_at"] as? String != nil)
}

@Test
func scheduledCommandPlainOutputAndLimitValidation() async throws {
  let path = try ScheduledCommandTestDatabase.makePath()
  let router = CommandRouter()

  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "scheduled", "list", "--db", path, "--limit", "1"])
  }
  #expect(status == 0)
  #expect(output.contains("scheduled-one"))
  #expect(output.contains("later one"))

  let (badOutput, badStatus) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "scheduled", "list", "--db", path, "--limit", "0"])
  }
  #expect(badStatus == 1)
  #expect(badOutput.contains("--limit"))
}

@Test
func rpcMessagesScheduledReturnsCanonicalRows() async throws {
  let store = try ScheduledCommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"scheduled","method":"messages.scheduled","params":{"limit":1}}"#
  )

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]]
  #expect(messages?.count == 1)
  #expect(messages?.first?["guid"] as? String == "scheduled-one")
}

@Test
func rpcMessagesScheduledRejectsInvalidParamsAndProposalAliases() async throws {
  let store = try ScheduledCommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  for request in [
    #"{"jsonrpc":"2.0","id":"string","method":"messages.scheduled","params":{"limit":"1"}}"#,
    #"{"jsonrpc":"2.0","id":"bool","method":"messages.scheduled","params":{"limit":true}}"#,
    #"{"jsonrpc":"2.0","id":"zero","method":"messages.scheduled","params":{"limit":0}}"#,
    #"{"jsonrpc":"2.0","id":"unknown","method":"messages.scheduled","params":{"chat_id":1}}"#,
    #"{"jsonrpc":"2.0","id":"array","method":"messages.scheduled","params":[]}"#,
    #"{"jsonrpc":"2.0","id":"old-list","method":"scheduledMessages.getScheduledMessages","params":{}}"#,
    #"{"jsonrpc":"2.0","id":"old-create","method":"scheduledMessages.createScheduledMessage","params":{}}"#,
  ] {
    await server.handleLineForTesting(request)
  }

  #expect(output.errors.count == 7)
  let codes = output.errors.compactMap { response in
    (response["error"] as? [String: Any])?["code"] as? Int
  }
  #expect(codes.prefix(5).allSatisfy { $0 == -32602 })
  #expect(Array(codes.suffix(2)) == [-32601, -32601])
}
