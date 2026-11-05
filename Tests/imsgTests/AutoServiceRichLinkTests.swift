import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func autoServiceRichLinkStore(guid: String) throws -> MessageStore {
  let db = try Connection(.inMemory)
  try CommandTestDatabase.createSchema(db, includeChatHandleJoin: true)
  try CommandTestDatabase.seedRPCChat(db)
  try db.run(
    "UPDATE chat SET guid = ?, chat_identifier = '+123', service_name = 'SMS' WHERE ROWID = 1",
    guid
  )
  return try MessageStore(connection: db, path: ":memory:")
}

private let autoServiceRichLinkPreview = PreparedRichLinkPreview(
  originalURL: "https://example.com/", resolvedURL: "https://example.com/",
  title: "Fixture", image: nil
)

@Test(arguments: ["any;-;+123", "any;+;chat123"])
func cliAutoServiceRichLinkUsesLiveBridgeWithStaleSMSService(guid: String) async throws {
  let store = try autoServiceRichLinkStore(guid: guid)
  let values = ParsedValues(
    positional: [], options: ["chat": [guid], "url": ["https://example.com/"]], flags: []
  )
  var actions: [BridgeAction] = []
  _ = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        actions.append(action)
        if action == .status {
          return ["selectors": ["urlPreviewMessage": true, "sendRichLinkAction": true]]
        }
        #expect(params["chatGuid"] as? String == guid)
        return ["messageGuid": "fixture-guid"]
      },
      storeFactory: { _ in store },
      prepareRichLink: { _ in autoServiceRichLinkPreview }
    )
  }
  #expect(actions == [.status, .sendRichLink])
}

@Test(arguments: [
  #""chat_id":1"#, #""chat_guid":"any;-;+123""#, #""chat_identifier":"+123""#,
])
func rpcAutoServiceRichLinkUsesExactExistingChatWithStaleSMSService(target: String) async throws {
  let store = try autoServiceRichLinkStore(guid: "any;-;+123")
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store, verbose: false, output: output,
    invokeBridge: { action, params in
      actions.append(action)
      if action == .status {
        return ["selectors": ["urlPreviewMessage": true, "sendRichLinkAction": true]]
      }
      #expect(params["chatGuid"] as? String == "any;-;+123")
      return ["messageGuid": "fixture-guid"]
    },
    prepareRichLink: { _ in autoServiceRichLinkPreview }
  )
  await server.handleLineForTesting(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"send.rich\",\"params\":{\(target),\"url\":\"https://example.com/\"}}"
  )
  #expect(output.errors.isEmpty)
  #expect(actions == [.status, .sendRichLink])
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["message_id"] as? String == "fixture-guid")
}

@Test
func autoServiceRichLinkStillRejectsExplicitSMSChatBeforeBridge() async throws {
  let store = try autoServiceRichLinkStore(guid: "SMS;-;+123")
  #expect(throws: (any Error).self) {
    try SendRichCommand.validateRichLinkChat(
      "SMS;-;+123", dbPath: ":memory:", storeFactory: { _ in store })
  }
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: store, verbose: false, output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return [:]
    },
    prepareRichLink: { _ in
      Issue.record("Explicit SMS must be rejected before metadata preparation")
      return autoServiceRichLinkPreview
    }
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"send.rich","params":{"chat_id":1,"url":"https://example.com/"}}"#
  )
  #expect(actions.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32602)
}
