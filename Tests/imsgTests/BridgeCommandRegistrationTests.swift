import Commander
import Foundation
import IMsgCore
import Testing

@testable import imsg

/// Snapshot of the bridge-backed commands we expect to be wired up. Locks in
/// the surface so an accidental drop from CommandRouter.specs gets caught
/// without exercising any IMCore plumbing.
@Test
func commandRouterIncludesAllBridgeCommands() {
  let router = CommandRouter()
  let expected: [String] = [
    "send-rich", "send-multipart", "send-attachment", "tapback",
    "poll", "edit", "unsend", "delete-message", "notify-anyways",
    "chat-create", "chat-name", "chat-photo",
    "chat-add-member", "chat-remove-member",
    "chat-leave", "chat-delete", "chat-mark",
    "account", "whois", "nickname",
  ]
  let registered = Set(router.specs.map { $0.name })
  for name in expected {
    #expect(registered.contains(name), "missing bridge command: \(name)")
  }
  #expect(registered.contains("search"), "missing local search command")
}

@Test
func bridgeMessagingCommandsExposeChatRequirement() async {
  // Each new bridge messaging command requires a `--chat` option (the chat
  // guid is the universal addressing key in v2). Ensure missing args bubble
  // up as a parse-time error rather than dropping into the bridge with empty
  // strings.
  let router = CommandRouter()
  let cases: [(name: String, args: [String])] = [
    ("send-rich", ["--text", "hello"]),
    ("poll", ["send", "--question", "Dinner?", "--option", "A", "--option", "B"]),
    ("edit", ["--message", "message-guid", "--new-text", "updated"]),
    ("unsend", ["--message", "message-guid"]),
    ("delete-message", ["--message", "message-guid"]),
    ("tapback", ["--message", "message-guid", "--kind", "love"]),
  ]
  for testCase in cases {
    let (output, status) = await StdoutCapture.capture {
      await router.run(argv: ["imsg", testCase.name] + testCase.args)
    }
    #expect(status == 1, "\(testCase.name) should require --chat")
    #expect(output.contains("Missing required option: --chat"))
  }
}

@Test
func bridgeAttachmentStagingUsesChatGuid() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let prepareBody = try #require(
    functionBody(
      named: "prepareOutgoingTransfer",
      in: source
    ))
  let sendAttachmentBody = try #require(
    functionBody(
      named: "handleSendAttachment",
      in: source
    ))

  #expect(
    source.range(
      of: #"prepareOutgoingTransfer\s*\([^)]*NSString\s*\*chatGuid\s*,\s*NSString\s*\*\*outErr\)"#,
      options: .regularExpression
    ) != nil)
  #expect(
    prepareBody.contains(
      "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:"))
  #expect(prepareBody.contains("[inv setArgument:&cg atIndex:5];"))
  #expect(
    sendAttachmentBody.contains("prepareOutgoingTransfer(fileURL, filename, chatGuid, &prepErr)"))
}

@Test
func bridgeReplySendsKeepAssociatedMessageFallback() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))

  for function in ["handleSendMessage", "handleSendMultipart", "handleSendAttachment"] {
    let body = try #require(functionBody(named: function, in: source))
    #expect(body.contains("selectedMessageGuid.length ? 100 : 0"))
    #expect(body.contains("selectedMessageGuid"))
    #expect(body.contains("associatedType"))
  }
}

@Test
func injectedHelperWiresNativePollSend() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let sendPollBody = try #require(functionBody(named: "handleSendPoll", in: source))

  #expect(source.contains("send-poll"))
  #expect(source.contains("com.apple.messages.Polls"))
  #expect(source.contains("MSMessageTemplateLayout"))
  #expect(source.contains("MSMessageLiveLayout"))
  #expect(source.contains(#""liveLayoutInfo""#))
  #expect(source.contains(#""ai""#))
  #expect(source.contains(#""sendAsText": @YES"#))
  #expect(source.contains(#""supports-polls""#))
  #expect(source.contains("__kIMBreadcrumbTextMarkerAttributeName"))
  #expect(source.contains("pollPreviewImageData"))
  #expect(sendPollBody.contains("buildPollCreationPayloadData"))
  #expect(sendPollBody.contains("buildPollIMMessage"))
  #expect(!sendPollBody.contains(#"selectedMessageGuid.length ? @"" : question"#))
  #expect(sendPollBody.contains("buildPollCreationPayloadData(question,"))
  #expect(sendPollBody.contains(#"@{ @"enc": @YES, @"ust": @YES }"#))
  #expect(sendPollBody.contains("selectedMessageGuid"))
  #expect(sendPollBody.contains("deriveThreadIdentifier"))
  #expect(sendPollBody.contains("setThreadOriginator:"))
  #expect(sendPollBody.contains("parentMessage"))
  #expect(sendPollBody.contains("parentItem"))
  #expect(sendPollBody.contains("threadIdentifier"))
  #expect(!source.contains("threadStrategy"))
  #expect(!source.contains("debug-runtime-search"))
  #expect(
    sendPollBody.contains(
      "dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem)"
    ))
  #expect(
    source.contains(
      "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:"
    ))
}

@Test
func injectedHelperConstructorOnlySchedulesDelayedBootstrap() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let constructorBody = try #require(functionBody(named: "injectedInit", in: source))
  let bootstrapBody = try #require(functionBody(named: "bridgeBootstrap", in: source))

  #expect(constructorBody.contains("dispatch_after"))
  #expect(constructorBody.contains("dispatch_async"))
  #expect(constructorBody.contains("bridgeBootstrap();"))
  #expect(!constructorBody.contains("NSLog"))
  #expect(!constructorBody.contains("NSProcessInfo"))
  #expect(!constructorBody.contains("NSClassFromString"))
  #expect(!constructorBody.contains("IMDaemonController"))
  #expect(!constructorBody.contains("startFileWatcher"))
  #expect(!constructorBody.contains("startV2InboxWatcher"))

  #expect(bootstrapBody.contains("dispatch_once"))
  #expect(bootstrapBody.contains("@autoreleasepool"))
  #expect(bootstrapBody.contains("connectToDaemon"))
  #expect(bootstrapBody.contains("startFileWatcher()"))
  #expect(bootstrapBody.contains("startV2InboxWatcher()"))
  #expect(bootstrapBody.contains("registerEventObservers()"))
}

private func stripObjectiveCComments(_ source: String) -> String {
  source
    .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"//.*"#, with: "", options: .regularExpression)
}

private func functionBody(named name: String, in source: String) -> String? {
  guard let nameRange = source.range(of: name),
    let openBrace = source[nameRange.upperBound...].firstIndex(of: "{")
  else {
    return nil
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

@Test
func chatMarkRejectsConflictingFlags() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: [
      "imsg", "chat-mark", "--chat", "iMessage;-;+15551234567", "--read", "--unread",
    ])
  }
  #expect(status == 1)
  #expect(output.contains("Invalid value for option: --read"))
}

@Test
func expressiveSendEffectExpandsShortNames() {
  // Bubble effects map to MobileSMS.expressivesend.<name>.
  #expect(
    ExpressiveSendEffect.expand("invisibleink")
      == "com.apple.MobileSMS.expressivesend.invisibleink")
  #expect(
    ExpressiveSendEffect.expand("impact")
      == "com.apple.MobileSMS.expressivesend.impact")
  #expect(
    ExpressiveSendEffect.expand("loud")
      == "com.apple.MobileSMS.expressivesend.loud")
  #expect(
    ExpressiveSendEffect.expand("gentle")
      == "com.apple.MobileSMS.expressivesend.gentle")

  // Screen effects map to messages.effect.CK<TitleCase>Effect.
  #expect(
    ExpressiveSendEffect.expand("confetti")
      == "com.apple.messages.effect.CKConfettiEffect")
  #expect(
    ExpressiveSendEffect.expand("lasers")
      == "com.apple.messages.effect.CKLasersEffect")
  #expect(
    ExpressiveSendEffect.expand("celebration")
      == "com.apple.messages.effect.CKCelebrationEffect")

  // Case-insensitive on the short form.
  #expect(
    ExpressiveSendEffect.expand("InvisibleInk")
      == "com.apple.MobileSMS.expressivesend.invisibleink")

  // Already-expanded ids pass through untouched.
  let expanded = "com.apple.MobileSMS.expressivesend.impact"
  #expect(ExpressiveSendEffect.expand(expanded) == expanded)
  let screenExpanded = "com.apple.messages.effect.CKHeartEffect"
  #expect(ExpressiveSendEffect.expand(screenExpanded) == screenExpanded)

  // Unknown short names pass through so the dylib can return its own error.
  #expect(ExpressiveSendEffect.expand("totally-not-real") == "totally-not-real")
}

@Test
func chatCreateRejectsUnsupportedServiceBeforeBridgeLaunch() async {
  let values = ParsedValues(
    positional: [],
    options: [
      "addresses": ["+15551234567"],
      "service": ["SMS"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  do {
    try await ChatCreateCommand.run(values: values, runtime: runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .unsupportedService(let value):
      #expect(value == "SMS")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}
