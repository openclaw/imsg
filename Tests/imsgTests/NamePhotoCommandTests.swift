import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func namePhotoCommandIsRegisteredUnderCanonicalName() {
  let router = CommandRouter()

  #expect(router.specs.contains { $0.name == "name-photo" })
}

@Test
func namePhotoStatusInvokesOfferInspectionForChat() async throws {
  let values = ParsedValues(
    positional: ["status"],
    options: ["chat": ["iMessage;-;+15551234567"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await NamePhotoCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return [
          "can_inspect_offer": true,
          "can_share": true,
          "personal_nickname_loaded": true,
          "has_personal_nickname": true,
          "should_offer": false,
        ]
      }
    )
  }

  #expect(capturedAction == .shouldOfferNicknameSharing)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(output.contains("can_inspect_offer=true"))
  #expect(output.contains("can_share=true"))
  #expect(output.contains("personal_nickname_loaded=true"))
  #expect(output.contains("has_personal_nickname=true"))
  #expect(output.contains("should_offer=false"))
}

@Test
func namePhotoStatusPreservesUnknownOfferState() async throws {
  let values = ParsedValues(
    positional: ["status"],
    options: ["chat": ["iMessage;+;chat123"]],
    flags: []
  )

  let (output, _) = try await StdoutCapture.capture {
    try await NamePhotoCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, _ in
        ["can_inspect_offer": false, "can_share": false, "should_offer": NSNull()]
      }
    )
  }

  #expect(output.contains("should_offer=unknown"))
}

@Test
func namePhotoShareInvokesExplicitSharingAction() async throws {
  let values = ParsedValues(
    positional: ["share"],
    options: ["chat": ["iMessage;+;chat123"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await NamePhotoCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return [
          "requested": true,
          "share_selector":
            "allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:",
        ]
      }
    )
  }

  #expect(capturedAction == .shareNickname)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
  )
  #expect(payload["requested"] as? Bool == true)
  #expect(
    payload["share_selector"] as? String
      == "allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:"
  )
}

@Test
func namePhotoCommandRejectsMissingChatAndUnknownAction() async {
  let missingChat = ParsedValues(positional: ["status"], options: [:], flags: [])
  do {
    try await NamePhotoCommand.run(
      values: missingChat,
      runtime: RuntimeOptions(parsedValues: missingChat)
    )
    Issue.record("expected name-photo to require --chat")
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("--chat"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }

  let unknownAction = ParsedValues(
    positional: ["inspect"],
    options: ["chat": ["iMessage;+;chat123"]],
    flags: []
  )
  do {
    try await NamePhotoCommand.run(
      values: unknownAction,
      runtime: RuntimeOptions(parsedValues: unknownAction)
    )
    Issue.record("expected name-photo to reject an unknown action")
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("action"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test
func rpcAdvertisesNamePhotoCompatibilityMethods() {
  let methods = Set(kSupportedRPCMethods)

  #expect(methods.contains("contacts.shouldShareContact"))
  #expect(methods.contains("contacts.shareContactCard"))
}

@Test
func rpcNamePhotoMethodsResolveChatAndInvokeMatchingBridgeActions() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(BridgeAction, [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      switch action {
      case .shouldOfferNicknameSharing:
        return ["can_share": true, "should_offer": true]
      case .shareNickname:
        return ["requested": true]
      default:
        return [:]
      }
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"status","method":"contacts.shouldShareContact","params":{"chat_id":1}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"share","method":"contacts.shareContactCard","params":{"chat_id":1}}"#
  )

  #expect(calls.count == 2)
  #expect(calls[0].0 == .shouldOfferNicknameSharing)
  #expect(calls[0].1["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(calls[1].0 == .shareNickname)
  #expect(calls[1].1["chatGuid"] as? String == "iMessage;+;chat123")

  let statusResult = output.responses.first?["result"] as? [String: Any]
  #expect(statusResult?["ok"] as? Bool == true)
  #expect(statusResult?["can_share"] as? Bool == true)
  #expect(statusResult?["should_offer"] as? Bool == true)
  let shareResult = output.responses.last?["result"] as? [String: Any]
  #expect(shareResult?["ok"] as? Bool == true)
  #expect(shareResult?["requested"] as? Bool == true)
}

@Test
func rpcNamePhotoMethodsRequireNamedParamsAndChatTarget() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeCallCount = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeCallCount += 1
      return [:]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"positional","method":"contacts.shouldShareContact","params":[1]}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"missing","method":"contacts.shareContactCard","params":{}}"#
  )

  #expect(bridgeCallCount == 0)
  #expect(output.errors.count == 2)
  for response in output.errors {
    let error = response["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
  }
}

@Test
func injectedHelperUsesGuardedNamePhotoSelectorFamilies() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = try String(contentsOf: helper, encoding: .utf8)

  #expect(source.contains("should-offer-nickname-sharing"))
  #expect(source.contains("share-nickname"))
  #expect(source.contains("@selector(sharedInstance)"))
  #expect(source.contains("@selector(nicknameForHandle:)"))
  #expect(source.contains("@selector(imHandleWithID:)"))
  #expect(source.contains("@selector(shouldOfferNicknameSharingForChat:)"))
  #expect(
    source.contains("allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:")
  )
  #expect(source.contains("fromHandle:(NSString *)fromHandleID"))
  #expect(!source.contains("allowHandlesForNicknameSharing:forChat:(NSArray"))
  #expect(!source.contains("whitelistHandlesForNicknameSharing:forChat:"))

  let controllerBody = try #require(
    objectiveCFunctionBody(named: "sharedNicknameController", in: source)
  )
  #expect(controllerBody.contains("@selector(sharedInstance)"))
  #expect(!controllerBody.contains("sharedController"))

  let senderBody = try #require(
    objectiveCFunctionBody(named: "nicknameSenderHandleID", in: source)
  )
  #expect(senderBody.contains("lastAddressedHandleID"))
  #expect(senderBody.contains("chat.account.loginIMHandle"))
  #expect(!senderBody.contains("activeIMessageAccount"))

  let statusBody = try #require(
    objectiveCFunctionBody(named: "handleShouldOfferNicknameSharing", in: source)
  )
  #expect(statusBody.contains("resolveChatByGuid(chatGuid)"))
  #expect(statusBody.contains("serviceNameForChat(chat, chatGuid)"))
  #expect(statusBody.contains(#"isEqualToString:@"iMessage""#))
  #expect(statusBody.contains(#"isEqualToString:@"iMessageLite""#))
  #expect(statusBody.contains("nicknameSharingSelectorStatus()"))
  #expect(statusBody.contains("shouldOfferNicknameSharingForChat:"))
  #expect(statusBody.contains(#"@"should_offer""#))
  #expect(statusBody.contains(#"@"can_share""#))
  #expect(statusBody.contains(#"@"has_personal_nickname""#))
  #expect(statusBody.contains(#"@"personal_nickname_loaded""#))
  #expect(statusBody.contains("@selector(personalNickname)"))
  #expect(statusBody.contains("waitForNicknameControllerLoad(controller, 1.0)"))
  #expect(!statusBody.contains("forceSend = YES"))
  #expect(!statusBody.contains(#"@"requested": @YES"#))

  let shareBody = try #require(
    objectiveCFunctionBody(named: "handleShareNickname", in: source)
  )
  #expect(shareBody.contains("resolveChatByGuid(chatGuid)"))
  #expect(shareBody.contains("serviceNameForChat(chat, chatGuid)"))
  #expect(shareBody.contains(#"isEqualToString:@"iMessage""#))
  #expect(shareBody.contains(#"isEqualToString:@"iMessageLite""#))
  #expect(shareBody.contains("participants"))
  #expect(shareBody.contains("nicknameSharingMutationSelectorName"))
  #expect(shareBody.contains("@selector(personalNickname)"))
  #expect(shareBody.contains("waitForNicknameControllerLoad(controller, 2.0)"))
  #expect(shareBody.contains("Personal Name & Photo is still loading"))
  #expect(shareBody.contains("No personal Name & Photo is configured in Messages"))
  #expect(shareBody.contains("forceSend = YES"))
  #expect(!shareBody.contains("else {"))
  #expect(shareBody.contains("objc_msgSend"))
  #expect(shareBody.contains(#"@"requested": @YES"#))
}

@Test
func injectedHelperMaterializesHandleForNicknameLookup() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = try String(contentsOf: helper, encoding: .utf8)
  let lookupBody = try #require(
    objectiveCFunctionBody(named: "handleGetNicknameInfo", in: source)
  )

  #expect(lookupBody.contains("sharedNicknameController()"))
  #expect(lookupBody.contains("@selector(imHandleWithID:)"))
  #expect(lookupBody.contains("@selector(nicknameForHandle:), handle"))
  #expect(!lookupBody.contains("sharedController"))
  #expect(!lookupBody.contains("withObject:address"))
}

private func objectiveCFunctionBody(named name: String, in source: String) -> String? {
  var searchStart = source.startIndex
  while let nameRange = source.range(of: name, range: searchStart..<source.endIndex) {
    guard let openBrace = source[nameRange.upperBound...].firstIndex(of: "{") else {
      return nil
    }
    if let semicolon = source[nameRange.upperBound...].firstIndex(of: ";"), semicolon < openBrace {
      searchStart = source.index(after: semicolon)
      continue
    }

    var depth = 0
    var index = openBrace
    while index < source.endIndex {
      if source[index] == "{" {
        depth += 1
      } else if source[index] == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[openBrace...index])
        }
      }
      index = source.index(after: index)
    }
    return nil
  }
  return nil
}
