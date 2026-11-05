import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func namePhotoSetRequiresCapabilityBeforeStagingOrMutation() async throws {
  let values = ParsedValues(
    positional: ["set"], options: ["firstName": ["Ada"], "photo": ["/fixture/ada.jpg"]], flags: [])
  var actions: [BridgeAction] = []
  var staged = false
  do {
    try await NamePhotoCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, _ in
        actions.append(action)
        return ["selectors": [:]]
      },
      stagePhoto: { _ in
        staged = true
        return "/staged/ada.jpg"
      })
    Issue.record("Unsupported helpers must refuse the identity change")
  } catch {
    #expect(String(describing: error).contains("does not support setting Name & Photo"))
  }
  #expect(actions == [.status])
  #expect(!staged)

  let output = TestRPCOutput()
  actions = []
  let server = RPCServer(
    store: try CommandTestDatabase.makeStoreForRPC(), verbose: false, output: output,
    invokeBridge: { action, _ in
      actions.append(action)
      return ["selectors": [:]]
    },
    stageAttachment: { _ in
      staged = true
      return "/staged/ada.jpg"
    })
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"contacts.setNamePhoto","params":{"first_name":"Ada","file":"/fixture/ada.jpg"}}"#
  )
  #expect(actions == [.status])
  #expect(!staged)
  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 1)
}

@Test
func namePhotoReadsAndMissingActionNeverSetIdentity() async throws {
  for action in ["status", ""] {
    let values = ParsedValues(
      positional: action.isEmpty ? [] : [action],
      options: [
        "chat": ["iMessage;+;fixture"], "firstName": ["Ada"], "photo": ["/fixture/ada.jpg"],
      ],
      flags: [])
    var actions: [BridgeAction] = []
    _ = try? await StdoutCapture.capture {
      try await NamePhotoCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        invokeBridge: { action, _ in
          actions.append(action)
          return [:]
        },
        stagePhoto: { _ in
          Issue.record("Read paths must not stage photos")
          return ""
        })
    }
    #expect(actions == (action.isEmpty ? [] : [.shouldOfferNicknameSharing]))
  }

  var actions: [BridgeAction] = []
  let server = RPCServer(
    store: try CommandTestDatabase.makeStoreForRPC(), verbose: false, output: TestRPCOutput(),
    invokeBridge: { action, _ in
      actions.append(action)
      return ["selectors": ["namePhotoSet": true]]
    },
    stageAttachment: { _ in
      Issue.record("Discovery must not stage photos")
      return ""
    })
  for method in ["initialize", "status"] {
    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":{}}")
  }
  #expect(actions.allSatisfy { !$0.isMutation })
}
