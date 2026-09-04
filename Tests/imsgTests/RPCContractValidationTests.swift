import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcMalformedWatchParamsDoNotAllocateSubscription() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  let invalidRequests = [
    #"{"jsonrpc":"2.0","id":"array","method":"watch.subscribe","params":[]}"#,
    #"{"jsonrpc":"2.0","id":"chat","method":"watch.subscribe","params":{"chat_id":"bogus"}}"#,
    #"{"jsonrpc":"2.0","id":"typo","method":"watch.subscribe","params":{"chatId":1}}"#,
    #"{"jsonrpc":"2.0","id":"participants","method":"watch.subscribe","params":{"participants":["+123",1]}}"#,
    #"{"jsonrpc":"2.0","id":"boolean","method":"watch.subscribe","params":{"attachments":"false"}}"#,
  ]

  for request in invalidRequests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == invalidRequests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"valid","method":"watch.subscribe","params":{"chat_id":1,"since_rowid":999}}"#
  )
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(rpcInt64(result?["subscription"]) == 1)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"cleanup","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )
}

@Test
func rpcWatchBufferLimitIsStrictAndBounded() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  let invalidRequests = [
    #"{"jsonrpc":"2.0","id":"zero","method":"watch.subscribe","params":{"buffer_limit":0}}"#,
    #"{"jsonrpc":"2.0","id":"large","method":"watch.subscribe","params":{"buffer_limit":4097}}"#,
    #"{"jsonrpc":"2.0","id":"bool","method":"watch.subscribe","params":{"buffer_limit":true}}"#,
    #"{"jsonrpc":"2.0","id":"string","method":"watch.subscribe","params":{"buffer_limit":"2"}}"#,
    #"{"jsonrpc":"2.0","id":"aliases","method":"watch.subscribe","params":{"buffer_limit":2,"bufferLimit":2}}"#,
  ]

  for request in invalidRequests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == invalidRequests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(await server.subscriptions.count == 0)
}

@Test
func rpcRejectsUnknownKeysAcrossHandlerFamilies() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var sent = false
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      sent = true
      return options
    },
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    }
  )
  let requests = [
    #"{"jsonrpc":"2.0","id":"read","method":"messages.history","params":{"chat_id":1,"extra":true}}"#,
    #"{"jsonrpc":"2.0","id":"send","method":"send","params":{"to":"+123","text":"hi","extra":true}}"#,
    #"{"jsonrpc":"2.0","id":"chat","method":"chats.delete","params":{"chat_id":1,"extra":true}}"#,
    #"{"jsonrpc":"2.0","id":"bridge","method":"message.delete","params":{"chat_id":1,"message_id":"m","extra":true}}"#,
  ]

  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(!sent)
  #expect(bridgeCalls == 0)
}

@Test
func rpcChatsCreateRejectsInvalidServiceAndAddressesBeforeBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    }
  )
  let invalidParams = [
    #"{"addresses":["+123"],"service":"auto"}"#,
    #"{"addresses":["+123"],"service":"sms"}"#,
    #"{"addresses":["+123"],"service":""}"#,
    #"{"addresses":[]}"#,
    #"{"addresses":["","   "]}"#,
    #"{"addresses":["+123",42]}"#,
  ]

  for (index, params) in invalidParams.enumerated() {
    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":\"invalid-\(index)\","
        + "\"method\":\"chats.create\",\"params\":\(params)}"
    )
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == invalidParams.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(bridgeCalls == 0)
}

@Test
func rpcRejectsConflictingTargetsBeforeMutations() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var sent = false
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      sent = true
      return options
    },
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"selectors","method":"chats.delete","params":{"chat_id":1,"chat_guid":"iMessage;+;other"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"recipient","method":"send","params":{"to":"+123","chat_id":1,"text":"hi"}}"#
  )

  #expect(output.errors.count == 2)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(!sent)
  #expect(bridgeCalls == 0)
}

@Test
func rpcRejectsCoercedNumericAndBooleanValues() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  let requests = [
    #"{"jsonrpc":"2.0","id":"string","method":"messages.history","params":{"chat_id":"1"}}"#,
    #"{"jsonrpc":"2.0","id":"bool-chat","method":"messages.history","params":{"chat_id":true}}"#,
    #"{"jsonrpc":"2.0","id":"bool-limit","method":"chats.list","params":{"limit":false}}"#,
    #"{"jsonrpc":"2.0","id":"number-bool","method":"chats.list","params":{"unread_only":1}}"#,
    #"{"jsonrpc":"2.0","id":"sms-fallback","method":"send","params":{"to":"+123","text":"hi","allow_sms_fallback":1}}"#,
  ]

  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
}

@Test
func rpcRejectsDocumentedInvalidSemanticValuesBeforeSideEffects() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  var stageCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    },
    stageSticker: { _ in
      stageCalls += 1
      throw StickerAssetError.couldNotStage("must not stage")
    }
  )
  let requests = [
    #"{"jsonrpc":"2.0","id":"history-id","method":"messages.history","params":{"chat_id":0}}"#,
    #"{"jsonrpc":"2.0","id":"history-limit","method":"messages.history","params":{"chat_id":1,"limit":0}}"#,
    #"{"jsonrpc":"2.0","id":"chats-limit","method":"chats.list","params":{"limit":-1}}"#,
    #"{"jsonrpc":"2.0","id":"search-empty","method":"messages.search","params":{"query":"   "}}"#,
    #"{"jsonrpc":"2.0","id":"search-match","method":"messages.search","params":{"query":"hello","match":"prefix"}}"#,
    #"{"jsonrpc":"2.0","id":"search-limit","method":"messages.search","params":{"query":"hello","limit":101}}"#,
    #"{"jsonrpc":"2.0","id":"watch-id","method":"watch.subscribe","params":{"chat_id":-1}}"#,
    #"{"jsonrpc":"2.0","id":"send-id","method":"send","params":{"chat_id":0,"text":"hi"}}"#,
    #"{"jsonrpc":"2.0","id":"subscription","method":"watch.unsubscribe","params":{"subscription":0}}"#,
    #"{"jsonrpc":"2.0","id":"empty-to","method":"read","params":{"to":""}}"#,
    #"{"jsonrpc":"2.0","id":"empty-chat","method":"chats.delete","params":{"chat_guid":""}}"#,
    #"{"jsonrpc":"2.0","id":"empty-address","method":"group.addParticipant","params":{"chat_id":1,"address":""}}"#,
    #"{"jsonrpc":"2.0","id":"negative-part","method":"send.sticker","params":{"#
      + #""chat_id":1,"file":"sticker.png","attach_to":"parent-guid","part_index":-1}}"#,
    #"{"jsonrpc":"2.0","id":"poll-comment","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Q","options":["A","B"],"comment":"caption","#
      + #""suppress_comment":true}}"#,
  ]

  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(bridgeCalls == 0)
  #expect(stageCalls == 0)
}

@Test
func rpcMultipartRejectsInvalidPartsBeforeBridgeDispatch() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    }
  )
  let tooMany = Array(repeating: #"{"text":"x"}"#, count: 21).joined(separator: ",")
  let params = [
    #"{}"#,
    #"{"parts":[]}"#,
    #"{"parts":["text"]}"#,
    #"{"parts":[{"text":""}]}"#,
    #"{"parts":[{"text":1}]}"#,
    #"{"parts":[{"text":"hi","extra":true}]}"#,
    #"{"parts":[{"text":"hi","file":"photo.jpg"}]}"#,
    #"{"parts":[{"text":"hi","attachment":{}}]}"#,
    #"{"parts":[{"text":"hi","mention":"+123"}]}"#,
    #"{"parts":[{"text":"hi","text_formatting":[]}],"effect":1}"#,
    #"{"chat_id":1,"parts":[{"text":"hi","textFormatting":[],"text_formatting":[]}]}"#,
    "{\"chat_id\":1,\"parts\":[\(tooMany)]}",
  ]

  for (index, value) in params.enumerated() {
    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":\"multipart-\(index)\","
        + "\"method\":\"send.multipart\",\"params\":\(value)}"
    )
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == params.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(bridgeCalls == 0)
}

@Test
func rpcRejectsConflictingAliasesBeforeSideEffects() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  var sendCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      sendCalls += 1
      return options
    },
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return [:]
    }
  )
  let requests = [
    #"{"jsonrpc":"2.0","id":"chat-list","method":"chats.list","params":{"unread_only":false,"unreadOnly":false}}"#,
    #"{"jsonrpc":"2.0","id":"watch","method":"watch.subscribe","params":{"debounce_ms":1,"debounceMs":1}}"#,
    #"{"jsonrpc":"2.0","id":"send-format","method":"send","params":{"to":"+123","text":"hi","formatting":[],"textFormatting":[]}}"#,
    #"{"jsonrpc":"2.0","id":"send-reply","method":"send","params":{"to":"+123","text":"hi","reply_to":"a","replyTo":"a"}}"#,
    #"{"jsonrpc":"2.0","id":"send-fallback","method":"send","params":{"#
      + #""to":"+123","text":"hi","allow_sms_fallback":true,"allowSMSFallback":true}}"#,
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"hi","message":"hi"}}"#,
    #"{"jsonrpc":"2.0","id":"attachment","method":"send.attachment","params":{"chat_id":1,"file":"a","path":"a"}}"#,
    #"{"jsonrpc":"2.0","id":"attachment-audio","method":"send.attachment","params":{"#
      + #""chat_id":1,"file":"a","audio":false,"is_audio":false}}"#,
    #"{"jsonrpc":"2.0","id":"attachment-part","method":"send.attachment","params":{"#
      + #""chat_id":1,"file":"a","reply_to":"m","part_index":0,"partIndex":0}}"#,
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"#
      + #""chat_id":1,"question":"Q","options":["A","B"],"suppress_comment":false,"#
      + #""suppressComment":false}}"#,
    #"{"jsonrpc":"2.0","id":"poll-vote","method":"poll.vote","params":{"chat_id":1,"poll_guid":"p","pollGuid":"p","option_id":"o"}}"#,
    #"{"jsonrpc":"2.0","id":"poll-option","method":"poll.vote","params":{"#
      + #""chat_id":1,"poll_guid":"p","option_id":"o","optionIndex":1}}"#,
    #"{"jsonrpc":"2.0","id":"tapback","method":"tapback","params":{"chat_id":1,"message_id":"m","reaction":"like","kind":"like"}}"#,
    #"{"jsonrpc":"2.0","id":"edit","method":"message.edit","params":{"chat_id":1,"message_id":"m","text":"x","newText":"x"}}"#,
    #"{"jsonrpc":"2.0","id":"part","method":"message.unsend","params":{"chat_id":1,"message_id":"m","part_index":0,"partIndex":0}}"#,
    #"{"jsonrpc":"2.0","id":"message","method":"message.delete","params":{"chat_id":1,"message_id":"m","messageId":"m"}}"#,
  ]

  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  #expect(bridgeCalls == 0)
  #expect(sendCalls == 0)
}

@Test
func rpcMapsInvalidISODatesToInvalidParams() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"history","method":"messages.history","params":{"chat_id":1,"start":"not-a-date"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"watch","method":"watch.subscribe","params":{"end":"still-not-a-date"}}"#
  )

  #expect(output.errors.count == 2)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
  let data = (output.errors.first?["error"] as? [String: Any])?["data"] as? String
  #expect(data?.contains("Invalid ISO8601 date") == true)
}

@Test
func rpcNotificationsNeverEmitResponsesOrErrors() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"chats.list","params":{"limit":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"watch.subscribe","params":{"chat_id":"bogus"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"missing.method","params":{}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"chats.list","params":[]}"#
  )

  #expect(output.responses.isEmpty)
  #expect(output.errors.isEmpty)
}

@Test
func rpcRequiresVersionAndValidRequestIDs() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  let requests = [
    #"{"id":"missing-version","method":"chats.list"}"#,
    #"{"jsonrpc":"2.0","id":true,"method":"chats.list"}"#,
    #"{"jsonrpc":"2.0","id":{},"method":"chats.list"}"#,
    #"{"jsonrpc":"2.0","id":[],"method":"chats.list"}"#,
  ]

  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32600 })
  #expect(output.errors.dropFirst().allSatisfy { $0["id"] is NSNull })
  #expect(output.errors.first?["id"] as? String == "missing-version")
}

@Test
func rpcNullIDRemainsARequestWhileAbsentIDRemainsANotification() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":null,"method":"chats.list","params":{"limit":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","method":"chats.list","params":{"limit":1}}"#
  )

  #expect(output.responses.count == 1)
  #expect(output.responses.first?["id"] is NSNull)
  #expect(output.errors.isEmpty)
}

@Test
func rpcRejectsNullAndScalarParams() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  for request in [
    #"{"jsonrpc":"2.0","id":"null","method":"chats.list","params":null}"#,
    #"{"jsonrpc":"2.0","id":"scalar","method":"chats.list","params":1}"#,
    #"{"jsonrpc":"2.0","id":"array","method":"chats.list","params":[]}"#,
  ] {
    await server.handleLineForTesting(request)
  }

  #expect(output.errors.count == 3)
  #expect(output.errors.allSatisfy { rpcErrorCode($0) == -32602 })
}

@Test
func rpcOpenClawFormattingAliasesRemainSupported() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var formattingPayloads: [[[String: Any]]] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      formattingPayloads.append(params["textFormatting"] as? [[String: Any]] ?? [])
      return ["messageGuid": "sent-guid"]
    },
    isBridgeReady: { true }
  )

  for alias in ["formatting", "textFormatting", "text_formatting"] {
    let request =
      #"{"jsonrpc":"2.0","id":"\#(alias)","method":"send","params":{"#
      + #""to":"+123","text":"hello","\#(alias)":[{"start":0,"length":5,"styles":["bold"]}]}}"#
    await server.handleLineForTesting(
      request
    )
  }

  #expect(output.errors.isEmpty)
  #expect(output.responses.count == 3)
  #expect(formattingPayloads.count == 3)
  #expect(formattingPayloads.allSatisfy { $0.first?["styles"] as? [String] == ["bold"] })
}

private func rpcErrorCode(_ envelope: [String: Any]) -> Int64? {
  rpcInt64((envelope["error"] as? [String: Any])?["code"])
}

private func rpcInt64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}
