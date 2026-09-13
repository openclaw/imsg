import Foundation
import Testing

@Test
func injectedHelperWiresStickerSendAction() throws {
  let source = stripObjectiveCComments(try injectedHelperSource())
  let sendStickerBody = try #require(bridgeFunctionBody(named: "handleSendSticker", in: source))
  let secureOpenBody = try #require(
    bridgeFunctionBody(named: "openUserOwnedDirectorySecurely", in: source))
  let cleanupBody = try #require(
    bridgeFunctionBody(named: "cleanupPreparedStickerPaths", in: source))
  let resolveChatBody = try #require(
    bridgeFunctionBody(named: "resolveChatByGuid", in: source))

  #expect(source.contains("send-sticker"))
  #expect(source.contains("markTransferAsSticker"))
  #expect(source.contains("stickerSend"))
  #expect(source.contains("stickerTransferCenter"))
  #expect(source.contains("setStickerUserInfo:"))
  #expect(source.contains("setAttributionInfo:"))
  #expect(source.contains("stickerMD5"))
  #expect(source.contains("CGImageSourceCreateWithData"))
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
  #expect(secureOpenBody.contains("open(root.fileSystemRepresentation"))
  #expect(secureOpenBody.contains("O_DIRECTORY | O_NOFOLLOW"))
  #expect(secureOpenBody.contains("fstat(directoryFD, &rootInfo)"))
  #expect(secureOpenBody.contains("[directory isEqualToString:root]"))
  #expect(secureOpenBody.contains("substringFromIndex:root.length + 1"))
  #expect(!secureOpenBody.contains("actualUserHomeDirectory"))
  #expect(secureOpenBody.contains("openat(directoryFD"))
  #expect(secureOpenBody.contains("fstat(nextFD, &componentInfo)"))
  #expect(cleanupBody.contains("removeStickerTransferFileSecurely(activePath)"))
  #expect(resolveChatBody.contains(#"[parts[1] isEqualToString:@"-"]"#))
}

@Test
func bridgeAttachmentStagingUsesChatGuid() throws {
  let source = stripObjectiveCComments(try injectedHelperSource())
  let prepareBody = try #require(
    bridgeFunctionBody(named: "prepareOutgoingTransfer", in: source))
  let sendAttachmentBody = try #require(
    bridgeFunctionBody(named: "handleSendAttachment", in: source))

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
