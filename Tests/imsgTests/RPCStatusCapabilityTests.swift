import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcStatusCalculatesDynamicMethodsAcrossResourceStates() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  let readyOutput = TestRPCOutput()
  let readyServer = RPCServer(
    store: store,
    verbose: false,
    output: readyOutput,
    invokeBridge: { action, _ in action == .status ? rpcStatusBridgeSnapshot() : [:] },
    isBridgeReady: { true }
  )
  await readyServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"both","method":"status"}"#)
  let both = try rpcStatusResult(readyOutput)
  let bothMethods = rpcStatusMethods(both)
  #expect(
    bothMethods.isSuperset(of: [
      "chats.list", "send.sticker", "poll.send", "poll.vote",
      "typing", "read", "message.edit", "message.unsend", "group.rename",
    ]))
  let readyBridge = try #require(both["bridge"] as? [String: Any])
  #expect(readyBridge["ready"] as? Bool == true)
  #expect(readyBridge["registry_available"] as? Bool == true)
  #expect(readyBridge["rpc_methods"] == nil)
  let readyDatabase = try #require(both["database"] as? [String: Any])
  let features = try #require(readyDatabase["features"] as? [String: Any])
  #expect(
    Set(features.keys) == [
      "unread_state", "scheduled_messages", "reactions", "reply_context",
      "routing_metadata", "balloon_payloads",
    ])

  let databaseOnlyOutput = TestRPCOutput()
  let databaseOnlyInvocations = RPCStatusInvocationCounter()
  let databaseOnlyServer = RPCServer(
    store: store,
    verbose: false,
    output: databaseOnlyOutput,
    invokeBridge: { _, _ in
      databaseOnlyInvocations.increment()
      return [:]
    },
    isBridgeReady: { false }
  )
  await databaseOnlyServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"database-only","method":"status"}"#)
  let databaseOnlyMethods = rpcStatusMethods(try rpcStatusResult(databaseOnlyOutput))
  #expect(databaseOnlyMethods.contains("chats.list"))
  #expect(databaseOnlyMethods.contains("typing"))
  #expect(databaseOnlyMethods.contains("read"))
  #expect(!databaseOnlyMethods.contains("group.rename"))
  #expect(databaseOnlyInvocations.value == 0)

  let bridgeOnlyOutput = TestRPCOutput()
  let bridgeOnlyServer = makeUnavailableRPCStatusServer(
    output: bridgeOnlyOutput,
    bridgeReady: true,
    invokeBridge: { action, _ in action == .status ? rpcStatusBridgeSnapshot() : [:] })
  await bridgeOnlyServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bridge-only","method":"status"}"#)
  let bridgeOnlyMethods = rpcStatusMethods(try rpcStatusResult(bridgeOnlyOutput))
  #expect(bridgeOnlyMethods.contains("group.rename"))
  #expect(bridgeOnlyMethods.contains("poll.send"))
  #expect(!bridgeOnlyMethods.contains("chats.list"))
  #expect(!bridgeOnlyMethods.contains("send.sticker"))
  #expect(!bridgeOnlyMethods.contains("poll.vote"))

  var limitedSelectors = fullRPCStatusBridgeSelectors()
  limitedSelectors["stickerSend"] = false
  limitedSelectors["editMessageItem"] = false
  let limitedOutput = TestRPCOutput()
  let limitedServer = RPCServer(
    store: store,
    verbose: false,
    output: limitedOutput,
    invokeBridge: { action, _ in
      action == .status ? rpcStatusBridgeSnapshot(selectors: limitedSelectors) : [:]
    },
    isBridgeReady: { true }
  )
  await limitedServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"limited","method":"status"}"#)
  let limitedMethods = rpcStatusMethods(try rpcStatusResult(limitedOutput))
  #expect(!limitedMethods.contains("send.sticker"))
  #expect(!limitedMethods.contains("message.edit"))
  #expect(limitedMethods.contains("poll.send"))

  let ignoredAllowlistOutput = TestRPCOutput()
  let ignoredAllowlistServer = RPCServer(
    store: store,
    verbose: false,
    output: ignoredAllowlistOutput,
    invokeBridge: { action, _ in
      action == .status ? rpcStatusBridgeSnapshot(rpcMethods: ["group.rename"]) : [:]
    },
    isBridgeReady: { true }
  )
  await ignoredAllowlistServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"allowlist","method":"status"}"#)
  let ignoredAllowlist = try rpcStatusResult(ignoredAllowlistOutput)
  let ignoredAllowlistMethods = rpcStatusMethods(ignoredAllowlist)
  #expect(ignoredAllowlistMethods.contains("group.rename"))
  #expect(ignoredAllowlistMethods.contains("group.setIcon"))
  #expect(ignoredAllowlistMethods.contains("poll.send"))
  #expect((ignoredAllowlist["bridge"] as? [String: Any])?["rpc_methods"] == nil)
}

@Test
func rpcBridgeRequiresRegistryAndActionSelectors() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithPollVote()
  let noRegistryOutput = TestRPCOutput()
  let noRegistryServer = RPCServer(
    store: store,
    verbose: false,
    output: noRegistryOutput,
    invokeBridge: { action, _ in
      action == .status ? rpcStatusBridgeSnapshot(registryAvailable: false) : [:]
    },
    isBridgeReady: { true }
  )
  await noRegistryServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"no-registry","method":"status"}"#)
  let noRegistry = try rpcStatusResult(noRegistryOutput)
  let bridge = try #require(noRegistry["bridge"] as? [String: Any])
  #expect(bridge["ready"] as? Bool == false)
  #expect(bridge["registry_available"] as? Bool == false)
  #expect(!rpcStatusMethods(noRegistry).contains("group.rename"))
  #expect(rpcStatusMethods(noRegistry).contains("handles.check"))

  var selectors = fullRPCStatusBridgeSelectors()
  selectors["markChatUnread"] = false
  selectors["notifyAnyways"] = false
  selectors["checkIMessageAvailability"] = false
  let limitedOutput = TestRPCOutput()
  let limitedServer = RPCServer(
    store: store,
    verbose: false,
    output: limitedOutput,
    invokeBridge: { action, _ in
      action == .status ? rpcStatusBridgeSnapshot(selectors: selectors) : [:]
    },
    isBridgeReady: { true }
  )
  await limitedServer.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"action-selectors","method":"status"}"#)
  let methods = rpcStatusMethods(try rpcStatusResult(limitedOutput))
  #expect(!methods.contains("chats.markUnread"))
  #expect(!methods.contains("message.notifyAnyways"))
  #expect(!methods.contains("handles.check"))
  #expect(methods.contains("group.rename"))
}

@Test
func rpcPollDatabaseRequirementsMatchOlderSchemaFeatures() async throws {
  for (reactions, balloons, vote, unvote) in [
    (false, false, false, false),
    (true, false, false, false),
    (false, true, true, false),
    (true, true, true, true),
  ] {
    let store = try CommandTestDatabase.makeStoreForRPCFeatures(
      reactions: reactions,
      balloonPayloads: balloons
    )
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in action == .status ? rpcStatusBridgeSnapshot() : [:] },
      isBridgeReady: { true }
    )
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"features","method":"status"}"#)
    let methods = rpcStatusMethods(try rpcStatusResult(output))
    #expect(methods.contains("poll.vote") == vote)
    #expect(methods.contains("messages.poll.vote") == vote)
    #expect(methods.contains("poll.unvote") == unvote)
    #expect(methods.contains("polls.unvote") == unvote)
    #expect(methods.contains("messages.poll.unvote") == unvote)
  }
}

@Test
func rpcStaleReadyLockMapsBridgeReadFailureToBridgeUnavailable() async throws {
  let output = TestRPCOutput()
  let server = makeUnavailableRPCStatusServer(
    output: output,
    bridgeReady: true,
    invokeBridge: { action, _ in
      if action == .checkImessageAvailability {
        throw IMsgBridgeError.timeout(action: action.rawValue)
      }
      return rpcStatusBridgeSnapshot()
    }
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"stale","method":"handles.check","params":{"address":"+123"}}"#)
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(error["code"] as? Int == -32003)
  #expect(error["message"] as? String == "Bridge unavailable")
}

@Test
func rpcCancelledBridgeSnapshotEmitsNoDegradedResponse() async {
  let output = TestRPCOutput()
  let server = makeUnavailableRPCStatusServer(
    output: output,
    bridgeReady: true,
    invokeBridge: { _, _ in throw CancellationError() }
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"cancelled","method":"status"}"#)
  #expect(output.responses.isEmpty)
  #expect(output.errors.isEmpty)
}
