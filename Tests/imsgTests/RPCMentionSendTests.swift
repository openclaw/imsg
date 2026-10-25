import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func mentionCapableStatus() -> [String: Any] {
  [
    "selectors": ["sendMessage": true, "sendMultipart": true, "sendMentions": true] as [String: Any]
  ]
}

private func mentionErrorCode(_ envelope: [String: Any]?) -> Int? {
  ((envelope?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
}

@Test
func rpcSendRichSendsMentionsThroughCapableBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      actions.append(action)
      if action == .status { return mentionCapableStatus() }
      capturedParams = params
      return ["messageGuid": "mention-guid"]
    }
  )

  // 👋 is two UTF-16 units, so "Ann" starts at 3 and "Ben" at 11.
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"👋 Ann and Ben","#
      + #""text_formatting":[{"start":3,"length":3,"styles":["bold"]}],"#
      + #""mentions":[{"start":11,"length":3,"handle":"ben@example.com"},"#
      + #"{"start":3,"length":3,"handle":"+15555550123"}]}}"#
  )

  #expect(output.errors.isEmpty)
  #expect(actions == [.status, .sendMessage])
  let mentions = try #require(capturedParams["mentions"] as? [[String: Any]])
  #expect(mentions.count == 2)
  #expect(mentions.first?["start"] as? Int == 3)
  #expect(mentions.first?["length"] as? Int == 3)
  #expect(mentions.first?["handle"] as? String == "+15555550123")
  #expect(mentions.last?["start"] as? Int == 11)
  #expect(mentions.last?["handle"] as? String == "ben@example.com")
  #expect((capturedParams["textFormatting"] as? [[String: Any]])?.count == 1)

  actions = []
  capturedParams = [:]
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"plain","method":"send.rich","params":{"chat_id":1,"text":"hi","mentions":[]}}"#
  )

  #expect(actions == [.sendMessage])
  #expect(capturedParams["mentions"] == nil)
}

@Test
func rpcMultipartSendsPartMentionsThroughCapableBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
  }
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      actions.append(action)
      if action == .status { return mentionCapableStatus() }
      capturedParams = params
      _ = try store.withConnection { db in
        try db.run(
          "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, guid) "
            + "VALUES (6, 1, 'first hi Ann', ?, 1, 'iMessage', 'multipart-guid')",
          CommandTestDatabase.appleEpoch(Date())
        )
        try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
      }
      return ["chatGuid": "iMessage;+;chat123", "messageGuid": "multipart-guid"]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"multipart","method":"send.multipart","params":{"chat_id":1,"parts":["#
      + #"{"text":"first"},"#
      + #"{"text":"hi Ann","mentions":[{"start":3,"length":3,"handle":"+15555550123"}]}]}}"#
  )

  #expect(output.errors.isEmpty)
  #expect(actions == [.status, .sendMultipart])
  let parts = try #require(capturedParams["parts"] as? [[String: Any]])
  #expect(parts.first?["mentions"] == nil)
  let mentions = try #require(parts.last?["mentions"] as? [[String: Any]])
  #expect(mentions.first?["start"] as? Int == 3)
  #expect(mentions.first?["handle"] as? String == "+15555550123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["guid"] as? String == "multipart-guid")
}

@Test
func rpcMentionsFailBeforeDispatchOnBridgeWithoutSupport() async throws {
  let requests = [
    #"{"jsonrpc":"2.0","id":"rich","method":"send.rich","params":{"chat_id":1,"text":"hi Ann","#
      + #""mentions":[{"start":3,"length":3,"handle":"+15555550123"}]}}"#,
    #"{"jsonrpc":"2.0","id":"multipart","method":"send.multipart","params":{"chat_id":1,"parts":["#
      + #"{"text":"hi Ann","mentions":[{"start":3,"length":3,"handle":"+15555550123"}]}]}}"#,
  ]
  for request in requests {
    let store = try CommandTestDatabase.makeStoreForRPC()
    let output = TestRPCOutput()
    var actions: [BridgeAction] = []
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        actions.append(action)
        return ["selectors": ["sendMessage": true, "sendMultipart": true] as [String: Any]]
      }
    )

    await server.handleLineForTesting(request)

    #expect(actions == [.status], "\(request)")
    #expect(mentionErrorCode(output.errors.first) == -32603, "\(request)")
    let error = output.errors.first?["error"] as? [String: Any]
    #expect((error?["data"] as? String)?.contains("does not support mentions") == true)
  }
}

@Test
func rpcRejectsInvalidMentionsBeforeBridgeDispatch() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCalls += 1
      return mentionCapableStatus()
    }
  )
  let ann = #"{"start":3,"length":3,"handle":"+15555550123"}"#
  let richParams = [
    #"{"chat_id":1,"text":"hi Ann","mentions":{}}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":["+15555550123"]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":-1,"length":3,"handle":"+1"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":3,"length":0,"handle":"+1"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":"3","length":3,"handle":"+1"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":4,"length":3,"handle":"+1"}]}"#,
    #"{"chat_id":1,"text":"hi 👋","mentions":[{"start":3,"length":3,"handle":"+1"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":3,"length":3}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":3,"length":3,"handle":""}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":3,"length":3,"handle":"+1","name":"Ann"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","mentions":[{"start":3,"length":3,"handle":"+1"},{"start":4,"length":2,"handle":"+2"}]}"#,
    #"{"chat_id":1,"text":"hi Ann","file":"photo.jpg","mentions":["# + ann + #"]}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","mentions":[]}"#,
  ]
  let multipartParams = [
    #"{"chat_id":1,"parts":[{"text":"hi","mentions":["# + ann + #"]}]}"#,
    #"{"chat_id":1,"parts":[{"text":"hi Ann","mentions":[{"start":3,"length":3}]}]}"#,
    #"{"chat_id":1,"parts":[{"text":"Ann","mention":"+15555550123"}]}"#,
  ]
  let requests =
    richParams.map { ("send.rich", $0) } + multipartParams.map { ("send.multipart", $0) }

  for (index, (method, params)) in requests.enumerated() {
    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":\"mention-\(index)\",\"method\":\"\(method)\",\"params\":\(params)}"
    )
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(output.errors.allSatisfy { mentionErrorCode($0) == -32602 })
  #expect(bridgeCalls == 0)
}
