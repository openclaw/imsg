import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private struct SendVerificationTestError: Error {}

private struct PublicationSignal {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (self.stream, self.continuation) = AsyncStream.makeStream()
  }

  func publish() {
    self.continuation.yield(())
  }

  func wait() async {
    var iterator = self.stream.makeAsyncIterator()
    _ = await iterator.next()
  }
}

private enum StrictSendSurface: CaseIterable, CustomStringConvertible {
  case richFile
  case multipart

  var description: String {
    switch self {
    case .richFile: "send.rich file"
    case .multipart: "send.multipart"
    }
  }

  var publication: BridgeAction {
    switch self {
    case .richFile: .sendAttachment
    case .multipart: .sendMultipart
    }
  }

  func request(id: Bool = true) -> String {
    let idField = id ? #""id":"strict","# : ""
    switch self {
    case .richFile:
      return
        #"{"jsonrpc":"2.0","# + idField
        + #""method":"send.rich","params":{"chat_id":1,"file":"photo.jpg","text":"same text"}}"#
    case .multipart:
      return
        #"{"jsonrpc":"2.0","# + idField
        + #""method":"send.multipart","params":{"chat_id":1,"parts":[{"text":"same text"}]}}"#
    }
  }

  func bridgeResponse(for action: BridgeAction, messageGUID: String) -> [String: Any] {
    if action == .status {
      return [
        "attachment_metadata": true,
        "selectors": ["sendAttachment": true] as [String: Any],
      ]
    }
    return ["chatGuid": "iMessage;+;chat123", "messageGuid": messageGUID]
  }
}

private func makeGUIDVerificationStore() throws -> MessageStore {
  let store = try CommandTestDatabase.makeStoreForRPC()
  _ = try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
  }
  return store
}

private func addOtherChat(to store: MessageStore) throws {
  _ = try store.withConnection { db in
    try db.run(
      "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) "
        + "VALUES (2, 'other', 'iMessage;+;other', 'Other', 'iMessage')"
    )
  }
}

private func insertOutgoing(
  into store: MessageStore,
  rowID: Int64 = 6,
  chatID: Int64 = 1,
  guid: String,
  text: String = "same text"
) throws {
  _ = try store.withConnection { db in
    try db.run(
      "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, guid) "
        + "VALUES (?, 1, ?, ?, 1, 'iMessage', ?)",
      rowID,
      text,
      CommandTestDatabase.appleEpoch(Date()),
      guid
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
  }
}

private func handleAndCancelVerification(
  _ server: RPCServer,
  request: String,
  publication: PublicationSignal
) async {
  let task = Task { await server.handleLineForTesting(request) }
  await publication.wait()
  task.cancel()
  await task.value
}

private func assertUnknownDelivery(
  _ output: TestRPCOutput,
  operation: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  #expect(output.responses.isEmpty, sourceLocation: sourceLocation)
  let error = try #require(
    output.errors.first?["error"] as? [String: Any], sourceLocation: sourceLocation)
  let data = try #require(error["data"] as? [String: Any], sourceLocation: sourceLocation)
  #expect(error["code"] as? Int == -32001, sourceLocation: sourceLocation)
  #expect(data["disposition"] as? String == "may_have_completed", sourceLocation: sourceLocation)
  #expect(data["transport"] as? String == "bridge_v2", sourceLocation: sourceLocation)
  #expect(data["operation"] as? String == operation, sourceLocation: sourceLocation)
  #expect(data["retry_safe"] as? Bool == false, sourceLocation: sourceLocation)
}

@Test
func rpcStrictSendSurfacesRequireDatabaseBeforePublication() async throws {
  for surface in StrictSendSurface.allCases {
    let output = TestRPCOutput()
    var actions: [BridgeAction] = []
    let server = RPCServer(
      databasePath: "/unavailable/chat.db",
      verbose: false,
      output: output,
      storeFactory: { _ in throw SendVerificationTestError() },
      invokeBridge: { action, _ in
        actions.append(action)
        return surface.bridgeResponse(for: action, messageGUID: "must-not-send")
      },
      stageAttachment: { _ in "/staged/photo.jpg" },
      isBridgeReady: { true }
    )

    await server.handleLineForTesting(surface.request())

    #expect(actions.isEmpty, "\(surface)")
    #expect(output.responses.isEmpty, "\(surface)")
    #expect(
      (output.errors.first?["error"] as? [String: Any])?["code"] as? Int == -32002,
      "\(surface)"
    )
  }
}

@Test
func rpcStrictSendBaselineFailureIsPreDispatchInternalError() async throws {
  let store = try makeGUIDVerificationStore()
  _ = try store.withConnection { db in try db.run("DROP TABLE message") }
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

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"strict","method":"send.multipart","params":{"chat_guid":"iMessage;+;chat123","parts":[{"text":"same text"}]}}"#
  )

  #expect(bridgeCalls == 0)
  #expect((output.errors.first?["error"] as? [String: Any])?["code"] as? Int == -32603)
}

@Test
func rpcStrictSendSurfacesAcceptOnlyNewHelperGUIDInTargetChat() async throws {
  for surface in StrictSendSurface.allCases {
    let store = try makeGUIDVerificationStore()
    let output = TestRPCOutput()
    var actions: [BridgeAction] = []
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        actions.append(action)
        if action == surface.publication {
          try insertOutgoing(into: store, guid: "new-helper-guid")
        }
        return surface.bridgeResponse(for: action, messageGUID: "new-helper-guid")
      },
      stageAttachment: { _ in "/staged/photo.jpg" }
    )

    await server.handleLineForTesting(surface.request())

    #expect(actions.filter { $0 == surface.publication }.count == 1, "\(surface)")
    #expect(output.errors.isEmpty, "\(surface)")
    let result = try #require(output.responses.first?["result"] as? [String: Any])
    #expect((result["id"] as? NSNumber)?.int64Value == 6, "\(surface)")
    #expect(result["guid"] as? String == "new-helper-guid", "\(surface)")
    #expect(result["message_id"] as? String == "new-helper-guid", "\(surface)")
    #expect(result["chat_guid"] as? String == "iMessage;+;chat123", "\(surface)")
    if surface == .multipart {
      #expect(result["parts_count"] as? Int == 1)
    }
  }
}

@Test
func rpcStrictSendRejectsConcurrentIdenticalTextWithoutMatchingHelperGUID() async throws {
  for surface in StrictSendSurface.allCases {
    for bridgeGUID in ["", "different-helper-guid"] {
      let store = try makeGUIDVerificationStore()
      let output = TestRPCOutput()
      var publications = 0
      let publication = PublicationSignal()
      let server = RPCServer(
        store: store,
        verbose: false,
        output: output,
        invokeBridge: { action, _ in
          if action == surface.publication {
            publications += 1
            publication.publish()
            try insertOutgoing(into: store, guid: "unrelated-guid")
          }
          return surface.bridgeResponse(for: action, messageGUID: bridgeGUID)
        },
        stageAttachment: { _ in "/staged/photo.jpg" }
      )

      if bridgeGUID.isEmpty {
        await server.handleLineForTesting(surface.request())
      } else {
        await handleAndCancelVerification(
          server,
          request: surface.request(),
          publication: publication
        )
      }

      #expect(publications == 1, "\(surface), GUID: \(bridgeGUID)")
      try assertUnknownDelivery(output, operation: surface.publication.rawValue)
    }
  }
}

@Test
func rpcStrictSendRejectsOldHelperGUIDBelowBaseline() async throws {
  for surface in StrictSendSurface.allCases {
    let store = try makeGUIDVerificationStore()
    _ = try store.withConnection { db in
      try db.run("UPDATE message SET guid = 'old-helper-guid' WHERE ROWID = 5")
    }
    let output = TestRPCOutput()
    var publications = 0
    let publication = PublicationSignal()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        if action == surface.publication {
          publications += 1
          publication.publish()
        }
        return surface.bridgeResponse(for: action, messageGUID: "old-helper-guid")
      },
      stageAttachment: { _ in "/staged/photo.jpg" }
    )

    await handleAndCancelVerification(
      server,
      request: surface.request(),
      publication: publication
    )

    #expect(publications == 1, "\(surface)")
    try assertUnknownDelivery(output, operation: surface.publication.rawValue)
  }
}

@Test
func rpcStrictSendRejectsNewHelperGUIDInWrongChat() async throws {
  for surface in StrictSendSurface.allCases {
    let store = try makeGUIDVerificationStore()
    try addOtherChat(to: store)
    let output = TestRPCOutput()
    var publications = 0
    let publication = PublicationSignal()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        if action == surface.publication {
          publications += 1
          publication.publish()
          try insertOutgoing(into: store, chatID: 2, guid: "wrong-chat-guid")
        }
        return surface.bridgeResponse(for: action, messageGUID: "wrong-chat-guid")
      },
      stageAttachment: { _ in "/staged/photo.jpg" }
    )

    await handleAndCancelVerification(
      server,
      request: surface.request(),
      publication: publication
    )

    #expect(publications == 1, "\(surface)")
    try assertUnknownDelivery(output, operation: surface.publication.rawValue)
  }
}

@Test
func rpcStrictSendMapsPostPublicationDatabaseErrorsToUnknownDelivery() async throws {
  let store = try makeGUIDVerificationStore()
  let output = TestRPCOutput()
  var publications = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      if action == .sendMultipart {
        publications += 1
        _ = try store.withConnection { db in try db.run("DROP TABLE message") }
      }
      return ["messageGuid": "new-helper-guid"]
    }
  )

  await server.handleLineForTesting(StrictSendSurface.multipart.request())

  #expect(publications == 1)
  try assertUnknownDelivery(output, operation: BridgeAction.sendMultipart.rawValue)
}

@Test
func rpcStrictSendNotificationsRemainSilentAndPublishOnce() async throws {
  for surface in StrictSendSurface.allCases {
    let store = try makeGUIDVerificationStore()
    let output = TestRPCOutput()
    var publications = 0
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        if action == surface.publication { publications += 1 }
        return surface.bridgeResponse(for: action, messageGUID: "")
      },
      stageAttachment: { _ in "/staged/photo.jpg" }
    )

    await server.handleLineForTesting(surface.request(id: false))

    #expect(publications == 1, "\(surface)")
    #expect(output.outputs.isEmpty, "\(surface)")
  }
}

@Test
func rpcSendRichFileRejectsMissingAttachmentCapabilityBeforeStaging() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var actions: [BridgeAction] = []
  var stageCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return ["selectors": ["sendAttachment": false] as [String: Any]]
    },
    stageAttachment: { _ in
      stageCalls += 1
      return "/must-not-stage"
    }
  )

  await server.handleLineForTesting(StrictSendSurface.richFile.request())

  #expect(actions == [.status])
  #expect(stageCalls == 0)
  #expect(output.responses.isEmpty)
  #expect((output.errors.first?["error"] as? [String: Any])?["code"] as? Int == -32603)
}
