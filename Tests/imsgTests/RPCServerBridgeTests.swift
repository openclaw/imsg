import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcSendUsesBridgeWhenReadyAndExistingDirectChatResolves() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "bridge-guid", "chatGuid": "iMessage;-;+123", "service": "iMessage"]
    },
    isBridgeReady: { true }
  )

  let line = #"{"jsonrpc":"2.0","id":"3bridge","method":"send","params":{"to":"+123","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+123")
  #expect(capturedParams["message"] as? String == "yo")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "bridge")
  #expect(result?["guid"] as? String == "bridge-guid")
  #expect(result?["chat_guid"] as? String == "iMessage;-;+123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcSendForwardsReplyTargetAliasesToBridge() async throws {
  for alias in ["reply_to", "replyTo", "reply_to_guid", "message_guid"] {
    let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
    let output = TestRPCOutput()
    var appleScriptCalled = false
    var capturedAction: BridgeAction?
    var capturedParams: [String: Any] = [:]
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      sendMessage: { _ in appleScriptCalled = true },
      resolveSentMessage: { _, _, _, _ in nil },
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "bridge-guid"]
      },
      isBridgeReady: { true }
    )

    let line =
      #"{"jsonrpc":"2.0","id":"send-\#(alias)","method":"send","params":{"to":"+123","text":"yo","\#(alias)":"parent-guid"}}"#
    await server.handleLineForTesting(line)

    #expect(appleScriptCalled == false)
    #expect(capturedAction == .sendMessage)
    #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+123")
    #expect(capturedParams["message"] as? String == "yo")
    #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
    let result = output.responses.first?["result"] as? [String: Any]
    #expect(result?["transport"] as? String == "bridge")
    #expect(result?["guid"] as? String == "bridge-guid")
  }
}

@Test
func rpcSendForwardsCaptionedAttachmentReplyToBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedActions: [BridgeAction] = []
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, params in
      capturedActions.append(action)
      if action == .status {
        return ["attachment_metadata": true]
      }
      capturedParams = params
      return ["messageGuid": "bridge-guid"]
    },
    stageAttachment: { _ in "/tmp/staged-photo.jpg" },
    isBridgeReady: { true }
  )

  let line = #"""
    {
      "jsonrpc": "2.0",
      "id": "captioned-reply",
      "method": "send",
      "params": {
        "to": "+123",
        "text": "caption",
        "file": "photo.jpg",
        "reply_to": "parent-guid",
        "formatting": [{"start": 0, "length": 7, "styles": ["italic"]}]
      }
    }
    """#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(capturedActions == [.status, .sendAttachment])
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+123")
  #expect(capturedParams["filePath"] as? String == "/tmp/staged-photo.jpg")
  #expect(capturedParams["message"] as? String == "caption")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  let ranges = capturedParams["textFormatting"] as? [[String: Any]]
  #expect(ranges?.first?["styles"] as? [String] == ["italic"])
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "bridge")
  #expect(result?["guid"] as? String == "bridge-guid")
}

@Test
func rpcSendReplyAttachmentRejectsStaleBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedActions: [BridgeAction] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, _ in
      capturedActions.append(action)
      return action == .status ? ["bridge_version": 2] : ["messageGuid": "bridge-guid"]
    },
    stageAttachment: { _ in "/tmp/staged-photo.jpg" },
    isBridgeReady: { true }
  )

  let line = #"""
    {"jsonrpc":"2.0","id":"stale-reply","method":"send","params":{"to":"+123","file":"photo.jpg","reply_to":"parent-guid"}}
    """#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(capturedActions == [.status])
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(
    error?["data"] as? String
      == "running bridge does not support captioned or threaded attachments; restart Messages with the current imsg bridge"
  )
}

@Test
func rpcSendThreadsTextFormattingToBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, params in
      capturedParams = params
      return ["messageGuid": "bridge-guid", "chatGuid": "iMessage;-;+123", "service": "iMessage"]
    },
    isBridgeReady: { true }
  )

  // The OpenClaw gateway emits format ranges under the bare `formatting` key.
  let line = #"""
    {"jsonrpc":"2.0","id":"3fmt","method":"send","params":{"to":"+123","text":"hello world","formatting":[{"start":0,"length":5,"styles":["bold"]}]}}
    """#
  await server.handleLineForTesting(line)

  let ranges = capturedParams["textFormatting"] as? [[String: Any]]
  #expect(ranges?.count == 1)
  #expect(ranges?.first?["start"] as? Int == 0)
  #expect(ranges?.first?["length"] as? Int == 5)
  #expect(ranges?.first?["styles"] as? [String] == ["bold"])
  #expect(capturedParams["message"] as? String == "hello world")
}

@Test
func rpcSendWithoutFormattingOmitsTextFormatting() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, params in
      capturedParams = params
      return ["messageGuid": "bridge-guid", "chatGuid": "iMessage;-;+123", "service": "iMessage"]
    },
    isBridgeReady: { true }
  )

  let line = #"{"jsonrpc":"2.0","id":"3nofmt","method":"send","params":{"to":"+123","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedParams["textFormatting"] == nil)
}

@Test
func rpcSendAutoSMSDetectionKeepsAnyPrefixBridgeLookup() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  try store.withConnection { db in
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = 'any;-;+123', guid = 'any;-;+123'
      WHERE ROWID = 1
      """
    )
    try db.run(
      """
      INSERT INTO chat(
        ROWID, chat_identifier, guid, display_name, service_name,
        account_id, account_login, last_addressed_handle
      )
      VALUES (
        0, '+123', 'iMessage;-;+123', 'Old iMessage Chat', 'iMessage',
        'iMessage;+;me@icloud.com', 'me@icloud.com', '+123'
      )
      """
    )
    try db.run("ALTER TABLE handle ADD COLUMN service TEXT")
    try db.run("UPDATE handle SET service = 'SMS' WHERE id = '+123'")
  }
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "bridge-guid", "chatGuid": "any;-;+123", "service": "SMS"]
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3anysms","method":"send","params":{"to":"+123","text":"yo","transport":"bridge"}}"#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "any;-;+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "bridge")
}

@Test
func rpcSendAutoSMSDetectionDoesNotUseIMessageBridgeChat() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  try store.withConnection { db in
    try db.run("ALTER TABLE handle ADD COLUMN service TEXT")
    try db.run("UPDATE handle SET service = 'SMS' WHERE id = '+123'")
  }
  let output = TestRPCOutput()
  var bridgeCalled = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in
      bridgeCalled = true
      return [:]
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3imsms","method":"send","params":{"to":"+123","text":"yo","transport":"bridge"}}"#
  await server.handleLineForTesting(line)

  #expect(bridgeCalled == false)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["data"] as? String == "bridge transport requires an existing chat target")
}

@Test
func rpcSendFallsBackToAppleScriptWhenAutoBridgeFails() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in captured = options },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in throw IMsgBridgeError.dylibReturnedError("nope") },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3fallback","method":"send","params":{"to":"+123","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.recipient == "+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "applescript")
  #expect(result?["chat_guid"] as? String == "iMessage;-;+123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcSendReplyTargetRejectsAppleScriptFallbackWhenBridgeUnavailable() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var bridgeCalled = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in
      bridgeCalled = true
      return [:]
    },
    isBridgeReady: { false }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"reply-no-bridge","method":"send","params":{"to":"+123","text":"yo","reply_to":"parent-guid"}}"#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(bridgeCalled == false)
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(
    error?["data"] as? String
      == "reply_to requires bridge transport; AppleScript fallback cannot send threaded replies")
}

@Test
func rpcSendReplyTargetDoesNotFallbackToAppleScriptWhenBridgeFails() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var bridgeCalled = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in
      bridgeCalled = true
      throw IMsgBridgeError.dylibReturnedError("bridge unavailable")
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"reply-bridge-fails","method":"send","params":{"to":"+123","text":"yo","reply_to":"parent-guid"}}"#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(bridgeCalled == true)
  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect((error?["data"] as? String)?.contains("bridge unavailable") == true)
}

@Test
func rpcTypingResolvesExistingAnyPrefixChat() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = 'any;-;+123', guid = 'any;-;+123'
      WHERE ROWID = 1
      """
    )
  }
  let output = TestRPCOutput()
  var startedIdentifier: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    startTyping: { startedIdentifier = $0 },
    stopTyping: { _ in }
  )

  let line = #"{"jsonrpc":"2.0","id":"3typing","method":"typing","params":{"to":"+123"}}"#
  await server.handleLineForTesting(line)

  #expect(startedIdentifier == "any;-;+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
}
