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
  let sendAttachmentBody = try #require(
    functionBody(
      named: "handleSendAttachment",
      in: source
    ))

  let prepareSignature =
    #"prepareOutgoingTransfer\s*\([^)]*NSString\s*\*chatGuid\s*,"#
    + #"\s*BOOL\s+hideAttachment\s*,\s*NSString\s*\*mimeType\s*,"#
    + #"\s*NSString\s*\*\*outErr\)"#
  #expect(source.range(of: prepareSignature, options: .regularExpression) != nil)
  #expect(
    source.contains(
      "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:"))
  #expect(source.contains("[inv setArgument:&cg atIndex:5];"))
  #expect(
    sendAttachmentBody.contains("prepareOutgoingTransfer(fileURL, filename, chatGuid"))
  #expect(sendAttachmentBody.contains("NO, nil, &prepErr"))
}

@Test
func injectedHelperHardensRichLinkImageTransfer() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let sendBody = try #require(functionBody(named: "handleSendMessage", in: source))
  let dispatchBody = try #require(functionBody(named: "dispatchAction", in: source))
  let actualHomeBody = try #require(
    functionBody(named: "richLinkActualUserHomeDirectory", in: source))
  let trustedRootBody = try #require(
    functionBody(named: "trustedRichLinkStagingRoot", in: source))
  let secureOpenBody = try #require(
    functionBody(named: "openRichLinkDirectorySecurely", in: source))
  let readBody = try #require(functionBody(named: "readRichLinkPreviewData", in: source))
  let validateBody = try #require(
    functionBody(named: "validateRichLinkPreviewImage", in: source))
  let snapshotBody = try #require(
    functionBody(named: "writeRichLinkPreviewSnapshot", in: source))
  let unregisteredBody = try #require(
    functionBody(named: "prepareUnregisteredOutgoingTransfer", in: source))

  // Messages.app's sandbox home differs from the login user's home. Resolve
  // the staging root from the uid, verify that trusted root, then walk only
  // descendant directories without following symlinks before opening the image.
  #expect(actualHomeBody.contains("getpwuid(getuid())"))
  #expect(actualHomeBody.contains("entry->pw_dir"))
  #expect(trustedRootBody.contains("richLinkActualUserHomeDirectory()"))
  #expect(trustedRootBody.contains("Library/Messages/Attachments/imsg"))
  #expect(secureOpenBody.contains("trustedRichLinkStagingRoot()"))
  #expect(secureOpenBody.contains("rootStat.st_uid != getuid()"))
  #expect(secureOpenBody.contains("rootStat.st_mode & S_IWOTH"))
  #expect(secureOpenBody.contains("substringFromIndex:rootPrefix.length"))
  #expect(secureOpenBody.contains("openat(directoryFD"))
  #expect(secureOpenBody.contains("O_DIRECTORY | O_NOFOLLOW"))
  #expect(readBody.contains("openat(directoryFD"))
  #expect(readBody.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
  #expect(readBody.contains("fstat(fd, &before)"))
  #expect(readBody.contains("after.st_ino != before.st_ino"))

  // The descriptor is bound to the bytes and decoded shape. The helper then
  // snapshots those verified bytes into a private, exclusive file so the
  // eventual IMFileTransfer cannot be retargeted by replacing the input path.
  #expect(validateBody.contains(#"@"contentHash""#))
  #expect(validateBody.contains("richLinkSHA256(data)"))
  #expect(validateBody.contains("CGImageSourceGetCount(source) != 1"))
  let metadataCheck = try #require(validateBody.range(of: "if (!typeMatches || !properties"))
  let decode = try #require(validateBody.range(of: "CGImageSourceCreateImageAtIndex"))
  #expect(metadataCheck.lowerBound < decode.lowerBound)
  #expect(validateBody.contains("writeRichLinkPreviewSnapshot(data, contentHash"))
  #expect(snapshotBody.contains("mkdirat(rootFD, \"rich-links\", 0700)"))
  #expect(snapshotBody.contains("O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600"))

  // Construct the balloon before registering its hidden transfer. This keeps
  // failed archive/KVC construction from orphaning a daemon transfer.
  let prepare = try #require(
    sendBody.range(of: "prepareUnregisteredOutgoingTransfer(previewFile"))
  let construct = try #require(
    sendBody.range(of: "buildBalloonIMMessage(urlPreviewBalloonBundleIdentifier()"))
  let register = try #require(
    sendBody.range(of: "registerPreparedTransfer(richLinkTransfer"))
  #expect(prepare.lowerBound < construct.lowerBound)
  #expect(construct.lowerBound < register.lowerBound)
  #expect(unregisteredBody.contains("hideAttachment, mimeType, NO, outErr"))

  // URL previews have their own bridge action. Generic send-message rejects a
  // smuggled descriptor, while send-rich-link requires one before entering the
  // shared, strictly validated message builder.
  #expect(dispatchBody.contains(#"[action isEqualToString:@"send-message"]"#))
  #expect(
    dispatchBody.contains(
      #"if (params[@"richLinkPreview"] || params[@"richLinkURL"])"#))
  #expect(dispatchBody.contains(#"@"Use send-rich-link for URL previews""#))
  #expect(dispatchBody.contains(#"[action isEqualToString:@"send-rich-link"]"#))
  #expect(
    dispatchBody.contains(
      #"![params[@"richLinkPreview"] isKindOfClass:[NSDictionary class]]"#))
  #expect(dispatchBody.contains(#"@"Missing rich-link descriptor""#))
  #expect(dispatchBody.components(separatedBy: "return handleSendMessage").count == 3)

  // Rich-link preparation must not synchronously invoke the private data
  // detector controller on Messages' main loop.
  #expect(!source.contains("IMDDController"))
  #expect(!source.contains("scanOutgoingMessageForDataDetectors"))
  #expect(!source.contains("waitUntilDone:YES"))
}

@Test
func injectedHelperFindsNestedThreadReplyItems() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let recursiveBody = try #require(
    functionBody(named: "findMessageItemInObject", in: source)
  )
  let normalizationBody = try #require(
    functionBody(named: "normalizeFoundMessageItemWithChatContext", in: source)
  )
  let safeSelectorBody = try #require(
    functionBody(named: "safelyReadObjectSelector", in: source)
  )
  let lookupBody = try #require(
    functionBody(named: "findMessageItem", in: source)
  )
  let loadBody = try #require(
    functionBody(named: "loadParentFirstChatItem", in: source)
  )

  #expect(recursiveBody.contains("depth > 8"))
  #expect(recursiveBody.contains("valueWithNonretainedObject"))
  #expect(recursiveBody.contains("normalizeFoundMessageItem(object)"))
  #expect(recursiveBody.contains(#"@"_newChatItems""#))
  #expect(recursiveBody.contains(#"@"_item""#))
  #expect(recursiveBody.contains(#"@"messageItem""#))
  #expect(normalizationBody.contains("@selector(_imMessageItem)"))
  #expect(normalizationBody.contains("@selector(_newChatItems)"))
  #expect(normalizationBody.contains("isKindOfClass:partClass"))
  #expect(source.contains("_newChatItemsWithChatContext:"))
  #expect(source.contains("_newMessagePartsForMessageItem:chatContext:"))
  #expect(source.contains("findMessagePartInObject"))
  #expect(source.contains("findMessagePart(chat, messageGuid, partIndex)"))
  #expect(source.contains("if ([(IMMessagePartChatItem *)object index] == partIndex)"))
  #expect(lookupBody.contains("chatContextForPinnedChat:"))
  #expect(lookupBody.contains("normalizeFoundMessageItemWithChatContext"))
  #expect(safeSelectorBody.contains("@catch"))
  #expect(recursiveBody.contains("safelyReadObjectSelector"))
  #expect(loadBody.contains("normalizeFoundMessageItem(parent)"))
  #expect(lookupBody.contains("findMessageItemInObject"))
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
func bridgeV2InboxClaimsRequestBeforeDispatch() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let processBody = try #require(functionBody(named: "processV2InboxFile", in: source))
  let cleanupBody = try #require(functionBody(named: "cleanupOrphanedV2Claims", in: source))
  let scanBody = try #require(functionBody(named: "scanV2Inbox", in: source))
  let claim = try #require(
    processBody.range(of: "rename(inPath.UTF8String, claimPath.UTF8String)"))
  let read = try #require(
    processBody.range(of: "dataWithContentsOfFile:claimPath"))
  let dispatch = try #require(processBody.range(of: "processV2Envelope(envelope)"))

  #expect(processBody.contains(#"@"%@.processing.%d""#))
  #expect(processBody.contains("claimErrno != ENOENT"))
  #expect(processBody.contains("removeItemAtPath:claimPath"))
  #expect(!processBody.contains("processedRpcIds"))
  #expect(claim.lowerBound < read.lowerBound)
  #expect(read.lowerBound < dispatch.lowerBound)
  #expect(cleanupBody.contains("kill(ownerPID, 0)"))
  #expect(cleanupBody.contains("kV2ClaimMaxAge"))
  #expect(cleanupBody.contains("removeItemAtPath:path"))
  #expect(scanBody.contains("cleanupOrphanedV2Claims(entries)"))
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
  let buildPollBody = try #require(functionBody(named: "buildPollIMMessage", in: source))

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
  #expect(buildPollBody.contains("buildBalloonIMMessage(pollsBalloonBundleIdentifier()"))
  #expect(buildPollBody.contains("@[]"))
  #expect(sendPollBody.contains("pollPayloadMessageInitializerAvailable()"))
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
  let modernMessageInitializer =
    "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:"
    + "balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:"
    + "scheduleState:messageSummaryInfo:"
  #expect(source.contains(modernMessageInitializer))
}

@Test
func injectedHelperBroadcastsFailClosedNativePollVoteMetadata() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let voteBody = try #require(functionBody(named: "buildPollVoteIMMessage", in: source))
  let sendVoteBody = try #require(
    functionBody(named: "handleSendPollVoteMutation", in: source))

  #expect(source.contains("send-poll-vote"))
  #expect(source.contains("send-poll-unvote"))
  #expect(source.contains("Poll vote payload exceeds 4096 bytes"))
  #expect(source.contains(#"@"pollVoteMessage": @(pollVoteMessageInitializerAvailable())"#))
  #expect(sendVoteBody.contains("pollVoteMessageInitializerAvailable()"))
  #expect(!sendVoteBody.contains("pollPayloadMessageInitializerAvailable()"))
  #expect(source.contains("archivePollMutationEnvelope"))
  #expect(source.contains("pollParticipantHandle(voterHandle)"))
  #expect(source.contains("remainingOptionIdentifiers"))
  #expect(source.contains(#"@"ams": @"Sent a vote""#))
  #expect(source.contains(#"@"amb": pollsBalloonBundleIdentifier()"#))
  #expect(!source.contains(#"vote[@"eventType"] = @"removed""#))
  #expect(!source.contains(#"vote[@"removed"] = @YES"#))
  #expect(!source.contains("send-poll-add-option"))
  #expect(voteBody.contains("associatedMessageType"))
  #expect(voteBody.contains("BOOL balloonStamped = NO;"))
  #expect(voteBody.contains("BOOL payloadStamped = NO;"))
  #expect(
    voteBody.contains("if ([target respondsToSelector:@selector(setBalloonBundleID:)])")
  )
  #expect(voteBody.contains("if ([target respondsToSelector:@selector(setPayloadData:)])"))
  #expect(voteBody.contains("return (balloonStamped && payloadStamped) ? result : nil;"))
  #expect(
    !voteBody.contains(
      "|| ![target respondsToSelector:@selector(setPayloadData:)]"
    ))
}

@Test
func injectedHelperFallsBackToMacOS26ChatRemovalSelector() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = stripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
  let deleteBody = try #require(functionBody(named: "handleDeleteChat", in: source))

  #expect(source.contains(#"@"deleteChat""#))
  #expect(source.contains(#"@"removeChat""#))
  #expect(deleteBody.contains(#"NSSelectorFromString(@"deleteChat:")"#))
  #expect(deleteBody.contains(#"NSSelectorFromString(@"_chat_remove:")"#))
  #expect(deleteBody.contains("NSStringFromSelector(selectedSelector)"))
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
  let cleanupBody = try #require(functionBody(named: "injectedCleanup", in: source))
  let bundleGuard = try #require(bootstrapBody.range(of: "com.apple.MobileSMS"))
  let initializePaths = try #require(bootstrapBody.range(of: "initFilePaths()"))

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
  #expect(bundleGuard.lowerBound < initializePaths.lowerBound)
  #expect(bootstrapBody.contains("bridgeDidBootstrap = YES"))
  #expect(bootstrapBody.contains("connectToDaemon"))
  #expect(bootstrapBody.contains("startFileWatcher()"))
  #expect(bootstrapBody.contains("startV2InboxWatcher()"))
  #expect(bootstrapBody.contains("registerEventObservers()"))
  #expect(cleanupBody.contains("if (!bridgeDidBootstrap) return;"))
}

private func stripObjectiveCComments(_ source: String) -> String {
  source
    .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"//.*"#, with: "", options: .regularExpression)
}

private func functionBody(named name: String, in source: String) -> String? {
  var searchStart = source.startIndex
  while searchStart < source.endIndex,
    let nameRange = source.range(
      of: name,
      range: searchStart..<source.endIndex)
  {
    searchStart = nameRange.upperBound
    guard let openParenthesis = source[nameRange.upperBound...].firstIndex(of: "(") else {
      return nil
    }
    guard source[nameRange.upperBound..<openParenthesis].allSatisfy(\.isWhitespace) else {
      continue
    }

    var parenthesisDepth = 0
    var index = openParenthesis
    var closeParenthesis: String.Index?
    while index < source.endIndex {
      if source[index] == "(" {
        parenthesisDepth += 1
      } else if source[index] == ")" {
        parenthesisDepth -= 1
        if parenthesisDepth == 0 {
          closeParenthesis = index
          break
        }
      }
      index = source.index(after: index)
    }
    guard let closeParenthesis else { return nil }

    index = source.index(after: closeParenthesis)
    while index < source.endIndex, source[index].isWhitespace {
      index = source.index(after: index)
    }
    guard index < source.endIndex, source[index] == "{" else {
      continue
    }

    let openBrace = index
    var braceDepth = 0
    while index < source.endIndex {
      if source[index] == "{" {
        braceDepth += 1
      } else if source[index] == "}" {
        braceDepth -= 1
        if braceDepth == 0 {
          return String(source[openBrace...index])
        }
      }
      index = source.index(after: index)
    }
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
