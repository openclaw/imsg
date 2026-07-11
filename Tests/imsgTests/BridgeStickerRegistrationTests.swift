import Foundation
import Testing

@Test
func injectedHelperWiresStickerSendAction() throws {
  let source = try stickerBridgeSource()
  let sendStickerBody = try #require(stickerFunctionBody(named: "handleSendSticker", in: source))
  let secureOpenBody = try #require(
    stickerFunctionBody(named: "openUserOwnedDirectorySecurely", in: source))
  let cleanupBody = try #require(
    stickerFunctionBody(named: "cleanupPreparedStickerPaths", in: source))
  let resolveChatBody = try #require(
    stickerFunctionBody(named: "resolveChatByGuid", in: source))

  #expect(source.contains("send-sticker"))
  #expect(source.contains("markTransferAsSticker"))
  #expect(source.contains("stickerSend"))
  #expect(source.contains("stickerTransferCenter"))
  #expect(source.contains("setStickerUserInfo:"))
  #expect(source.contains("setAttributionInfo:"))
  #expect(source.contains("stickerSHA256"))
  #expect(source.contains("stickerMD5"))
  #expect(source.contains("CGImageSourceCreateWithData"))
  #expect(source.contains("O_NOFOLLOW"))
  #expect(source.contains("writeStickerSnapshot"))
  #expect(source.contains("removeStickerFileSecurely"))
  #expect(source.contains("cleanupPreparedStickerPaths"))
  #expect(source.contains("removeStickerTransferFileSecurely"))
  #expect(source.contains("hasStoredMessageWithGUID:"))
  #expect(source.contains("stickerAttachmentMessageInitializerAvailable"))
  #expect(source.contains("stickerAssociatedMessageInitializerAvailable"))
  #expect(source.contains("stickerTargetLookup"))
  #expect(source.contains("@\"shash\": md5"))
  #expect(source.contains("@\"sid\": filename"))
  #expect(source.contains(#""p:%ld/%@""#))
  #expect(sendStickerBody.contains("IMsgOutgoingTransferKindSticker"))
  #expect(sendStickerBody.contains("selectedMessageGuid.length ? 1000 : 0"))
  #expect(sendStickerBody.contains(#"@{@"eogcd": @3, @"ust": @YES}"#))
  #expect(sendStickerBody.contains("buildAttachmentAttributed(transferGuid, filename, 0)"))
  #expect(sendStickerBody.contains("findMessagePart(chat, selectedMessageGuid, targetPartIndex)"))
  #expect(sendStickerBody.contains("stickerMessageBelongsToChat"))
  #expect(sendStickerBody.contains("registerPreparedTransfer"))
  #expect(sendStickerBody.contains("targetPartIndex"))
  #expect(secureOpenBody.contains("open(home.fileSystemRepresentation"))
  #expect(secureOpenBody.contains("O_DIRECTORY | O_NOFOLLOW"))
  #expect(secureOpenBody.contains("fstat(directoryFD, &homeInfo)"))
  #expect(secureOpenBody.contains("substringFromIndex:home.length + 1"))
  #expect(secureOpenBody.contains("openat(directoryFD"))
  #expect(secureOpenBody.contains("fstat(nextFD, &componentInfo)"))
  #expect(cleanupBody.contains("removeStickerTransferFileSecurely(activePath)"))
  #expect(resolveChatBody.contains(#"[parts[1] isEqualToString:@"-"]"#))
  #expect(resolveChatBody.contains("vendIMHandle(hr, address, preferredService, NO)"))
}

@Test
func bridgeAttachmentStagingUsesChatGuid() throws {
  let source = try stickerBridgeSource()
  let prepareBody = try #require(
    stickerFunctionBody(named: "prepareOutgoingTransfer", in: source))
  let sendAttachmentBody = try #require(
    stickerFunctionBody(named: "handleSendAttachment", in: source))

  #expect(source.contains("IMsgOutgoingTransferKind transferKind"))
  #expect(source.contains("NSDictionary *transferMetadata"))
  #expect(source.contains("NSString **outActivePath"))
  #expect(source.contains("registerPreparedTransfer"))
  #expect(
    prepareBody.contains(
      "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:"))
  #expect(prepareBody.contains("[inv setArgument:&cg atIndex:5];"))
  #expect(prepareBody.contains("BOOL canRetargetSticker"))
  #expect(prepareBody.contains("pathIsWithinRoot(persistentPath"))
  #expect(prepareBody.contains("transferKind != IMsgOutgoingTransferKindSticker || retargeted"))
  #expect(sendAttachmentBody.contains("IMsgOutgoingTransferKindAttachment"))
}

private func stickerBridgeSource() throws -> String {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  return stickerStripObjectiveCComments(try String(contentsOf: helper, encoding: .utf8))
}

private func stickerStripObjectiveCComments(_ source: String) -> String {
  source.replacingOccurrences(
    of: #"/\*[\s\S]*?\*/|//[^\n]*"#,
    with: "",
    options: .regularExpression)
}

private func stickerFunctionBody(named name: String, in source: String) -> String? {
  var searchStart = source.startIndex
  while let nameRange = source.range(of: name, range: searchStart..<source.endIndex) {
    let suffix = source[nameRange.upperBound...]
    guard let openBrace = suffix.firstIndex(of: "{") else { return nil }
    if let semicolon = suffix.firstIndex(of: ";"), semicolon < openBrace {
      searchStart = nameRange.upperBound
      continue
    }
    var depth = 0
    var index = openBrace
    while index < source.endIndex {
      if source[index] == "{" { depth += 1 }
      if source[index] == "}" {
        depth -= 1
        if depth == 0 { return String(source[openBrace...index]) }
      }
      index = source.index(after: index)
    }
    return nil
  }
  return nil
}
