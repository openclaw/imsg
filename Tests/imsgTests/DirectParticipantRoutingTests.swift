import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(arguments: ["to", "chatID", "chatGUID", "chatIdentifier"])
func sendCommandSuppliesVerifiedParticipantRoute(target: String) async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let targetValue = target == "to" ? "+123" : (target == "chatID" ? "1" : "iMessage;-;+123")
  let values = ParsedValues(
    positional: [], options: ["db": [path], target: [targetValue], "text": ["hello"]],
    flags: ["noSMSFallback"])
  var captured: MessageSendOptions?
  _ = try await StdoutCapture.capture {
    try await SendCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      sendMessage: { captured = $0 }, resolveSentMessage: resolvedSentMessageFixture)
  }
  #expect(captured?.directParticipantTarget?.chatGUID == "iMessage;-;+123")
  #expect(captured?.directParticipantTarget?.recipient == "+123")
  #expect(captured?.directParticipantTarget?.accountID == "iMessage;+;me@icloud.com")
  #expect(captured?.allowSMSFallback == false)
}

@Test(arguments: ["to", "chat_id", "chat_guid", "chat_identifier"])
func rpcSuppliesVerifiedParticipantRoute(target: String) async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let store = try MessageStore(path: path)
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store, verbose: false, output: output,
    sendMessage: { captured = $0 }, resolveSentMessage: resolvedSentMessageFixture)
  let targetValue: Any = target == "to" ? "+123" : (target == "chat_id" ? 1 : "iMessage;-;+123")
  let request: [String: Any] = [
    "jsonrpc": "2.0", "id": 1, "method": "send",
    "params": [target: targetValue, "text": "hello", "transport": "applescript"],
  ]
  await server.handleLineForTesting(
    String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))
  #expect(output.errors.isEmpty)
  #expect(captured?.directParticipantTarget?.chatGUID == "iMessage;-;+123")
  #expect(captured?.directParticipantTarget?.recipient == "+123")
  #expect(captured?.directParticipantTarget?.accountID == "iMessage;+;me@icloud.com")
}

@Test
func groupWithOneRemainingParticipantDoesNotGetDirectRoute() throws {
  let store = try MessageStore(path: CommandTestDatabase.makePath())
  #expect(
    ChatTargetResolver.directParticipantTarget(
      store: store,
      resolvedTarget: ResolvedChatTarget(chatIdentifier: "", chatGUID: "iMessage;+;chat123"),
      directChatInfo: nil) == nil)
}
