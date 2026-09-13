import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcSendResolvesChatID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture,
    isBridgeReady: { false }
  )

  let line = #"{"jsonrpc":"2.0","id":"3","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.chatIdentifier == "iMessage;+;chat123")
  #expect(captured?.chatGUID == "iMessage;+;chat123")
  #expect(captured?.recipient.isEmpty == true)
  #expect(output.responses.first?["result"] as? [String: Any] != nil)
}

@Test
func rpcSendResolvesUniqueContactName() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let resolver = MockContactResolver(
    matches: [ContactMatch(name: "Alice Smith", handle: "+15551234567")]
  )
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture,
    contactResolver: resolver
  )

  let line = #"{"jsonrpc":"2.0","id":"3n","method":"send","params":{"to":"Alice","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.recipient == "+15551234567")
  #expect(output.responses.first?["result"] as? [String: Any] != nil)
}

@Test
func rpcSendRejectsAmbiguousContactName() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let resolver = MockContactResolver(
    matches: [
      ContactMatch(name: "John Smith", handle: "+15551234567"),
      ContactMatch(name: "John Doe", handle: "+15557654321"),
    ]
  )
  let server = RPCServer(store: store, verbose: false, output: output, contactResolver: resolver)

  let line = #"{"jsonrpc":"2.0","id":"3m","method":"send","params":{"to":"John","text":"yo"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(rpcTestInt64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsContactNameWhenContactsAreUnavailable() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let resolver = MockContactResolver(contactsUnavailable: true)
  var didSend = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      didSend = true
      return options
    },
    contactResolver: resolver
  )

  let line = #"{"jsonrpc":"2.0","id":"3u","method":"send","params":{"to":"Alice","text":"yo"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(rpcTestInt64Value(error?["code"]) == -32602)
  #expect(didSend == false)
}

@Test
func rpcSendReturnsSentMessageIdentifiersWhenResolved() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { $0 },
    resolveSentMessage: { _, options, chatID, _ in
      Message(
        rowID: 1_979,
        chatID: chatID ?? 0,
        sender: "me@icloud.com",
        text: options.text,
        date: Date(),
        isFromMe: true,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 0,
        guid: "8DF1B3D7"
      )
    },
    isBridgeReady: { false }
  )

  let line = #"{"jsonrpc":"2.0","id":"3b","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(rpcTestInt64Value(result?["id"]) == 1_979)
  #expect(result?["guid"] as? String == "8DF1B3D7")
  #expect(result?["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(result?["service"] as? String == "iMessage")
  #expect(result?["message_id"] as? String == "8DF1B3D7")
}

@Test
func rpcAttachmentOnlyKeepsOkResponseWithoutTextVerification() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { $0 },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3c","method":"send","params":{"chat_id":1,"file":"/tmp/photo.jpg"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["id"] == nil)
  #expect(result?["guid"] == nil)
  #expect(result?["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcSendReportsMisroutedChatGhost() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      try store.withConnection { db in
        try db.run("INSERT INTO handle(ROWID, id) VALUES (99, 'iMessage;+;chat123')")
        try db.run(
          """
          INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
          VALUES (99, 99, '', ?, 1, 'SMS')
          """,
          CommandTestDatabase.appleEpoch(Date())
        )
      }
      return options
    },
    resolveSentMessage: { _, _, _, _ in nil },
    isBridgeReady: { false }
  )

  let line = #"{"jsonrpc":"2.0","id":"3d","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(rpcTestInt64Value(error?["code"]) == -32001)
  #expect(data?["retry_safe"] as? Bool == false)
  #expect(data?["disposition"] as? String == "may_have_completed")
  #expect(data?["transport"] as? String == "applescript")
  #expect(data?["operation"] as? String == "send")
  #expect((data?["detail"] as? String)?.contains("unjoined empty outgoing row (99)") == true)
}

@Test
func rpcSendRejectsMissingTextAndFile() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"4","method":"send","params":{"to":"+15551234567"}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(rpcTestInt64Value(error?["code"]) == -32602)
}
