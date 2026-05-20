import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

final class TestRPCOutput: RPCOutput, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var responses: [[String: Any]] = []
  private(set) var errors: [[String: Any]] = []
  private(set) var notifications: [[String: Any]] = []

  func sendResponse(id: Any, result: Any) {
    record(&responses, value: ["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    record(&errors, value: payload)
  }

  func sendNotification(method: String, params: Any) {
    record(&notifications, value: ["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func record(_ bucket: inout [[String: Any]], value: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    bucket.append(value)
  }
}

private func int64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcChatsListReturnsChatPayload() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let resolver = MockContactResolver(names: ["iMessage;+;chat123": "Family"])
  let server = RPCServer(store: store, verbose: false, output: output, contactResolver: resolver)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.count == 1)
  let result = output.responses[0]["result"] as? [String: Any]
  let chats = result?["chats"] as? [[String: Any]] ?? []
  #expect(chats.count == 1)
  let chat = chats[0]
  #expect(int64Value(chat["id"]) == 1)
  #expect(chat["identifier"] as? String == "iMessage;+;chat123")
  #expect(chat["is_group"] as? Bool == true)
  #expect(chat["contact_name"] == nil)
  #expect((chat["participants"] as? [String])?.count == 2)
}

@Test
func rpcMessagesHistoryIncludesChatFields() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.count == 1)
  let message = messages[0]
  #expect(int64Value(message["chat_id"]) == 1)
  #expect(message["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(message["is_group"] as? Bool == true)
}

@Test
func rpcChatsCreateForwardsBridgeIdentityFields() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return [
        "chatGuid": "iMessage;+;chat987",
        "messageGuid": "created-message-guid",
        "service": "iMessage",
      ]
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"create","method":"chats.create","params":{"#
    + #""addresses":["+123","+456"],"service":"auto","name":"Group","text":"hello"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedAction == .createChat)
  #expect(capturedParams["addresses"] as? [String] == ["+123", "+456"])
  #expect(capturedParams["service"] as? String == "auto")
  #expect(capturedParams["displayName"] as? String == "Group")
  #expect(capturedParams["message"] as? String == "hello")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["chat_guid"] as? String == "iMessage;+;chat987")
  #expect(result?["message_guid"] as? String == "created-message-guid")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcHandlesCheckInvokesBridgeAndReturnsAvailability() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return [
        "address": "+14159369340",
        "alias_type": "phone",
        "destination": "tel:+14159369340",
        "id_status": 3,
        "available": true,
      ]
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"phone","service":"iMessage"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedAction == .checkImessageAvailability)
  #expect(capturedParams["address"] as? String == "+14159369340")
  #expect(capturedParams["aliasType"] as? String == "phone")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["address"] as? String == "+14159369340")
  #expect(result?["alias_type"] as? String == "phone")
  #expect(result?["destination"] as? String == "tel:+14159369340")
  #expect(int64Value(result?["id_status"]) == 3)
  #expect(result?["available"] as? Bool == true)
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcHandlesCheckRequiresAddress() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsInvalidAliasType() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"url"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsSmsService() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","service":"sms"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRequiresReadyBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeInvoked = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeInvoked = true
      return [:]
    },
    isBridgeReady: { false }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340"}}"#
  await server.handleLineForTesting(line)

  #expect(bridgeInvoked == false)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
}

@Test
func rpcMessagesHistoryReportsConvertedAttachmentsWhenRequested() async throws {
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("caf")
  try Data("caf".utf8).write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "m4a")
  try FileManager.default.createDirectory(
    at: converted.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("m4a".utf8).write(to: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let store = try CommandTestDatabase.makeStoreForRPCWithAttachment(
    filename: source.path,
    transferName: "voice.caf",
    uti: "com.apple.coreaudio-format",
    mimeType: "audio/x-caf"
  )
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"attachments":true,"convert_attachments":true}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  let attachments = messages.first?["attachments"] as? [[String: Any]]
  #expect(attachments?.first?["original_path"] as? String == source.path)
  #expect(attachments?.first?["converted_path"] as? String == converted.path)
  #expect(attachments?.first?["converted_mime_type"] as? String == "audio/mp4")
}

@Test
func rpcSendResolvesChatID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in captured = options },
    resolveSentMessage: { _, _, _, _ in nil }
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
    sendMessage: { options in captured = options },
    resolveSentMessage: { _, _, _, _ in nil },
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
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendReturnsSentMessageIdentifiersWhenResolved() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
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
    }
  )

  let line = #"{"jsonrpc":"2.0","id":"3b","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(int64Value(result?["id"]) == 1_979)
  #expect(result?["guid"] as? String == "8DF1B3D7")
  #expect(result?["chat_guid"] as? String == "iMessage;+;chat123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcSendKeepsOkResponseWhenSentMessageIsNotResolved() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  let line = #"{"jsonrpc":"2.0","id":"3c","method":"send","params":{"chat_id":1,"text":"yo"}}"#
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
    sendMessage: { _ in
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
    },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  let line = #"{"jsonrpc":"2.0","id":"3d","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
  #expect((error?["data"] as? String)?.contains("unjoined empty outgoing row") == true)
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
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcRejectsInvalidJSON() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("not-json")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32700)
}

@Test
func rpcStartupErrorServerPreservesJSONRPCFraming() async throws {
  let output = TestRPCOutput()
  let error = IMsgError.permissionDenied(
    path: "/tmp/chat.db",
    underlying: NSError(domain: "SQLite", code: 14)
  )
  let server = RPCStartupErrorServer(error: error, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"startup","method":"chats.list","params":{"limit":1}}"#
  )

  #expect(output.errors.count == 1)
  let envelope = output.errors[0]
  #expect(envelope["id"] as? String == "startup")
  let payload = envelope["error"] as? [String: Any]
  #expect(int64Value(payload?["code"]) == -32603)
  #expect(payload?["message"] as? String == "Internal error")
  let data = payload?["data"] as? String ?? ""
  #expect(data.contains("Permission Error"))
  #expect(data.contains("Full Disk Access"))
}

@Test
func rpcRejectsNonObjectRequest() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("[]")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsInvalidJSONRPCVersion() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"1.0","id":1,"method":"chats.list"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsMissingMethod() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcReportsMethodNotFound() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32601)
}

@Test
func rpcHistoryRequiresChatID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":5,"method":"messages.history","params":{"limit":5}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsInvalidService() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":6,"method":"send","params":{"to":"+15551234567","text":"hi","service":"fax"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsMissingRecipientForDirectSend() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":7,"method":"send","params":{"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsChatAndRecipient() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":8,"method":"send","params":{"chat_id":1,"to":"+15551234567","text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsUnknownChatID() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":9,"method":"send","params":{"chat_id":999,"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcWatchSubscribeEmitsNotificationAndUnsubscribe() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let subscribe =
    #"{"jsonrpc":"2.0","id":10,"method":"watch.subscribe","params":{"chat_id":1,"since_rowid":-1}}"#
  await server.handleLineForTesting(subscribe)

  let result = output.responses.first?["result"] as? [String: Any]
  let subscription = int64Value(result?["subscription"]) ?? 0
  #expect(subscription > 0)

  for _ in 0..<20 {
    if output.notifications.count >= 1 { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  #expect(output.notifications.count == 1)
  let params = output.notifications.first?["params"] as? [String: Any]
  #expect(int64Value(params?["subscription"]) == subscription)
  #expect(params?["message"] as? [String: Any] != nil)

  let unsubscribe =
    #"{"jsonrpc":"2.0","id":11,"method":"watch.unsubscribe","params":{"subscription":\#(subscription)}}"#
  await server.handleLineForTesting(unsubscribe)

  #expect(output.responses.count >= 2)
}

@Test
func rpcWatchIncludeReactionsDoesNotRequireAttachments() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithReaction()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let subscribe =
    #"{"jsonrpc":"2.0","id":13,"method":"watch.subscribe","params":{"chat_id":1,"#
    + #""since_rowid":-1,"include_reactions":true,"attachments":false}}"#
  await server.handleLineForTesting(subscribe)

  for _ in 0..<20 {
    if output.notifications.count >= 1 { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  let params = output.notifications.first?["params"] as? [String: Any]
  let message = params?["message"] as? [String: Any]
  let reactions = message?["reactions"] as? [[String: Any]] ?? []
  #expect(reactions.count == 1)
  #expect(reactions.first?["type"] as? String == "like")
  #expect((message?["attachments"] as? [[String: Any]])?.isEmpty == true)
}

@Test
func rpcWatchUnsubscribeRequiresSubscription() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":12,"method":"watch.unsubscribe","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}
