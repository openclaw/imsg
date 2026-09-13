static NSDictionary *handleSendAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    NSString *message = params[@"message"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;
    NSNumber *audioFlag = params[@"isAudioMessage"];
    BOOL isAudio = [audioFlag boolValue];
    NSArray *textFormatting = params[@"textFormatting"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!filePath.length) return errorResponse(requestId, @"Missing filePath");
    if (!message) message = @"";
    NSError *attrErr = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:filePath error:&attrErr];
    if (!attrs) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"File not found: %@", filePath]);
    }
    if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
        return errorResponse(requestId, @"Symlinked attachment paths are not allowed");
    }
    if (pathHasSymlinkComponent(filePath)) {
        return errorResponse(requestId, @"Attachment path traverses a symlink");
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"File not found: %@", filePath]);
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSString *filename = [fileURL lastPathComponent];

    @try {
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, filename, chatGuid, IMsgOutgoingTransferKindAttachment,
            nil, NULL, &prepErr);
        if (!transfer) {
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not register attachment transfer");
        }
        NSString *transferGuid = [transfer guid];
        if (!transferGuid.length) {
            return errorResponse(requestId, @"Transfer registered without guid");
        }

        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
        NSInteger attachmentPartIndex = partIndex;
        if (message.length) {
            NSString *textPrefix = [message stringByAppendingString:@"\n"];
            NSAttributedString *textBody = nil;
            if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
                textBody = buildFormattedAttributed(textPrefix, textFormatting, partIndex);
            } else {
                textBody = buildPlainAttributed(textPrefix, partIndex);
            }
            [body appendAttributedString:textBody];
            attachmentPartIndex = partIndex + 1;
        }
        [body appendAttributedString:buildAttachmentAttributed(transferGuid, filename,
                                                               attachmentPartIndex)];

        NSAttributedString *subjectAttr = subject.length
            ? buildPlainAttributed(subject, 0)
            : nil;
        long long associatedType = selectedMessageGuid.length ? 100 : 0;
        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendAttachment: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }

        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length), nil,
                                      @[transferGuid], isAudio, NO, nil);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build IMMessage with attachment");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register attachment transfer");
        }
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuid": transferGuid,
            @"selectedMessageGuid": selectedMessageGuid ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-attachment failed: %@", exception.reason]);
    }
}

/// `send-sticker`: registers an outgoing file transfer and marks the transfer
/// as sticker-attributed before dispatch. A selectedMessageGuid attaches the
/// sticker to a message bubble using the same association path as tapbacks.
static void cleanupPreparedStickerPaths(NSString *snapshotPath,
                                        NSString *activePath) {
    if (activePath.length) removeStickerTransferFileSecurely(activePath);
    if (snapshotPath.length
        && ![snapshotPath.stringByStandardizingPath
            isEqualToString:activePath.stringByStandardizingPath]) {
        removeStickerFileSecurely(snapshotPath);
    }
}

static NSDictionary *handleSendSticker(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    NSString *contentHash = params[@"contentHash"];
    NSString *accessibilityLabel = params[@"accessibilityLabel"];
    NSNumber *pixelWidth = params[@"pixelWidth"];
    NSNumber *pixelHeight = params[@"pixelHeight"];
    NSString *rawSelectedMessageGuid = params[@"selectedMessageGuid"];
    NSNumber *partIndexNum = params[@"targetPartIndex"];
    if (![chatGuid isKindOfClass:[NSString class]]
        || ![filePath isKindOfClass:[NSString class]]
        || ![contentHash isKindOfClass:[NSString class]]
        || ![accessibilityLabel isKindOfClass:[NSString class]]) {
        return errorResponse(requestId,
            @"chatGuid, filePath, contentHash, and accessibilityLabel must be strings");
    }
    if (![pixelWidth isKindOfClass:[NSNumber class]]
        || ![pixelHeight isKindOfClass:[NSNumber class]]
        || CFGetTypeID((__bridge CFTypeRef)pixelWidth) == CFBooleanGetTypeID()
        || CFGetTypeID((__bridge CFTypeRef)pixelHeight) == CFBooleanGetTypeID()
        || pixelWidth.doubleValue != (double)pixelWidth.integerValue
        || pixelHeight.doubleValue != (double)pixelHeight.integerValue) {
        return errorResponse(requestId, @"pixelWidth and pixelHeight must be integers");
    }
    if (rawSelectedMessageGuid
        && ![rawSelectedMessageGuid isKindOfClass:[NSString class]]) {
        return errorResponse(requestId, @"selectedMessageGuid must be a string");
    }
    if (partIndexNum && ![partIndexNum isKindOfClass:[NSNumber class]]) {
        return errorResponse(requestId, @"targetPartIndex must be an integer");
    }
    if (partIndexNum
        && (CFGetTypeID((__bridge CFTypeRef)partIndexNum) == CFBooleanGetTypeID()
            || partIndexNum.doubleValue != (double)partIndexNum.integerValue)) {
        return errorResponse(requestId, @"targetPartIndex must be an integer");
    }
    NSInteger targetPartIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!filePath.length) return errorResponse(requestId, @"Missing filePath");
    if (targetPartIndex < 0) {
        return errorResponse(requestId, @"targetPartIndex must be non-negative");
    }
    NSString *selectedMessageGuid = nil;
    NSInteger requestedPartIndex = targetPartIndex;
    if (!resolveMessagePartTarget(rawSelectedMessageGuid, &selectedMessageGuid, &targetPartIndex)) {
        return errorResponse(requestId, @"Malformed sticker target");
    }
    if (partIndexNum && requestedPartIndex != targetPartIndex) {
        return errorResponse(requestId, @"Conflicting sticker target parts");
    }
    if (!selectedMessageGuid.length && targetPartIndex != 0) {
        return errorResponse(requestId, @"targetPartIndex requires selectedMessageGuid");
    }
    if (!stickerAttachmentMessageInitializerAvailable()) {
        return errorResponse(requestId,
            @"Sticker attachment message initializer unavailable");
    }
    if (selectedMessageGuid.length
        && !stickerAssociatedMessageInitializerAvailable()) {
        return errorResponse(requestId,
            @"Sticker associated-message initializer unavailable");
    }
    if (!stickerTransferSelectorsAvailable()) {
        return errorResponse(requestId, @"Required sticker transfer selectors unavailable");
    }

    NSString *metadataErr = nil;
    NSDictionary *assetMetadata = stickerAssetMetadata(filePath, &metadataErr);
    if (!assetMetadata) {
        return errorResponse(requestId,
            metadataErr.length ? metadataErr : @"Invalid sticker image");
    }
    if (![assetMetadata[@"hash"] isEqualToString:contentHash.lowercaseString]
        || ![assetMetadata[@"width"] isEqualToNumber:pixelWidth]
        || ![assetMetadata[@"height"] isEqualToNumber:pixelHeight]) {
        return errorResponse(requestId, @"Sticker metadata does not match staged bytes");
    }
    NSMutableDictionary *verifiedMetadata = [assetMetadata mutableCopy];
    verifiedMetadata[@"accessibilityLabel"] = accessibilityLabel;

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Stickers require an iMessage chat");
    }
    if (![chat respondsToSelector:@selector(sendMessage:)]) {
        return errorResponse(requestId, @"Chat send selector unavailable");
    }
    NSString *resolvedChatGuid = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : chatGuid;

    id parentChatItem = nil;
    NSRange targetRange = NSMakeRange(0, 1);
    if (selectedMessageGuid.length) {
        if (!stickerMessageBelongsToChat(chat, selectedMessageGuid)) {
            return errorResponse(requestId,
                @"Sticker target does not belong to the selected chat");
        }
        parentChatItem = findMessagePart(chat, selectedMessageGuid, targetPartIndex);
        if (!parentChatItem
            || ![parentChatItem respondsToSelector:@selector(index)]
            || [(IMMessagePartChatItem *)parentChatItem index] != targetPartIndex
            || ![parentChatItem respondsToSelector:@selector(messagePartRange)]) {
            return errorResponse(requestId, @"Sticker target message part not found");
        }
        targetRange = [(IMMessagePartChatItem *)parentChatItem messagePartRange];
        if (targetRange.length == 0) {
            return errorResponse(requestId, @"Sticker target message part has an empty range");
        }
    }

    NSString *snapshotErr = nil;
    NSString *snapshotPath = writeStickerSnapshot(assetMetadata, filePath, &snapshotErr);
    if (!snapshotPath.length) {
        return errorResponse(requestId,
            snapshotErr.length ? snapshotErr : @"Could not snapshot sticker image");
    }
    if (!removeStickerFileSecurely(filePath)) {
        removeStickerFileSecurely(snapshotPath);
        return errorResponse(requestId, @"Could not remove sticker handoff file");
    }
    [verifiedMetadata removeObjectForKey:@"data"];
    verifiedMetadata[@"filename"] = snapshotPath.lastPathComponent;
    NSURL *fileURL = [NSURL fileURLWithPath:snapshotPath];
    NSString *filename = [fileURL lastPathComponent];

    BOOL dispatchAttempted = NO;
    NSString *activePath = snapshotPath;
    @try {
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, filename, resolvedChatGuid, IMsgOutgoingTransferKindSticker,
            verifiedMetadata, &activePath, &prepErr);
        if (!transfer) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not register sticker transfer");
        }
        NSString *transferGuid = [transfer guid];
        if (!transferGuid.length) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId, @"Sticker transfer registered without guid");
        }

        // Target and outgoing attachment part indexes are different domains.
        // A sticker message contains one outgoing attachment, always part 0.
        NSAttributedString *body = buildAttachmentAttributed(transferGuid, filename, 0);
        long long associatedType = selectedMessageGuid.length ? 1000 : 0;
        NSString *associatedRef = selectedMessageGuid;
        if (selectedMessageGuid.length) {
            associatedRef = [NSString stringWithFormat:@"p:%ld/%@",
                                                        (long)targetPartIndex,
                                                        selectedMessageGuid];
        }
        NSDictionary *summaryInfo = selectedMessageGuid.length
            ? @{@"eogcd": @3, @"ust": @YES}
            : nil;
        clearThreadContextForChat(chat, nil);

        id imMessage = buildIMMessage(body, nil, nil, nil,
                                      nil,
                                      associatedRef, associatedType,
                                      targetRange, summaryInfo,
                                      @[transferGuid], NO, NO, nil);
        if (!imMessage) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId, @"Could not build sticker IMMessage");
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register sticker transfer");
        }
        dispatchAttempted = YES;
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuid": transferGuid,
            @"selectedMessageGuid": selectedMessageGuid ?: @"",
            @"targetPartIndex": @(targetPartIndex)
        });
    } @catch (NSException *exception) {
        if (!dispatchAttempted) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
        }
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-sticker failed: %@", exception.reason]);
    }
}

/// `send-reaction`: builds a reaction IMMessage tied to the target guid.
