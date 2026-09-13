static NSDictionary *handleSendMessage(NSInteger requestId, NSDictionary *params) {
    id chatGuidValue = params[@"chatGuid"];
    id messageValue = params[@"message"];
    id effectIdValue = params[@"effectId"];
    id subjectValue = params[@"subject"];
    id selectedMessageGuidValue = params[@"selectedMessageGuid"];
    id richLinkValue = params[@"richLinkPreview"];
    id partIndexValue = params[@"partIndex"];
    id ddScanValue = params[@"ddScan"];
    id attributedBodyValue = params[@"attributedBody"];
    id textFormattingValue = params[@"textFormatting"];
    id clientMessageGuidValue = params[@"clientMessageGuid"];
    if (![chatGuidValue isKindOfClass:[NSString class]] ||
        (messageValue && ![messageValue isKindOfClass:[NSString class]]) ||
        (effectIdValue && ![effectIdValue isKindOfClass:[NSString class]]) ||
        (subjectValue && ![subjectValue isKindOfClass:[NSString class]]) ||
        (selectedMessageGuidValue &&
         ![selectedMessageGuidValue isKindOfClass:[NSString class]]) ||
        (richLinkValue && ![richLinkValue isKindOfClass:[NSDictionary class]]) ||
        (partIndexValue && !richLinkIntegerNumber(partIndexValue)) ||
        (ddScanValue && ![ddScanValue isKindOfClass:[NSNumber class]]) ||
        (attributedBodyValue && ![attributedBodyValue isKindOfClass:[NSString class]]) ||
        (textFormattingValue && ![textFormattingValue isKindOfClass:[NSArray class]]) ||
        (clientMessageGuidValue &&
         ![clientMessageGuidValue isKindOfClass:[NSString class]])) {
        return errorResponse(requestId, @"Invalid send-message parameter types");
    }

    NSString *chatGuid = chatGuidValue;
    NSString *message = messageValue;
    NSString *effectId = effectIdValue;
    NSString *subject = subjectValue;
    NSString *selectedMessageGuid = selectedMessageGuidValue;
    NSDictionary *richLinkPreview = richLinkValue;
    NSNumber *partIndexNum = partIndexValue;
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;
    NSNumber *ddScanNum = ddScanValue;
    BOOL ddScan = [ddScanNum boolValue];
    NSString *attributedBodyB64 = attributedBodyValue;
    NSArray *textFormatting = textFormattingValue;
    NSString *clientMessageGuid = nil;
    if (clientMessageGuidValue) {
        NSUUID *clientUUID = [[NSUUID alloc] initWithUUIDString:clientMessageGuidValue];
        if (!clientUUID) {
            return errorResponse(requestId, @"clientMessageGuid must be a UUID");
        }
        if (!clientMessageGuidInitializerAvailable()) {
            return errorResponse(requestId, @"Caller-owned message GUIDs are unavailable");
        }
        clientMessageGuid = clientUUID.UUIDString.lowercaseString;
    }

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!message) message = @"";
    if (clientMessageGuid.length && richLinkPreview) {
        return errorResponse(requestId, @"Caller-owned message GUIDs support text messages only");
    }
    if (richLinkPreview &&
        (effectId.length || subject.length || selectedMessageGuid.length || partIndex != 0 ||
         attributedBodyB64.length || textFormatting.count || !ddScan)) {
        return errorResponse(requestId, @"Rich links do not support send modifiers");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (richLinkPreview) {
        NSString *serviceName = serviceNameForChat(chat, chatGuid).lowercaseString;
        if (!([serviceName isEqualToString:@"imessage"] ||
              [serviceName isEqualToString:@"imessagelite"])) {
            return errorResponse(requestId, @"Rich links require an iMessage chat");
        }
    }

    NSAttributedString *body = attributedBodyFromBase64(attributedBodyB64);
    if (!body) {
        if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
            body = buildFormattedAttributed(message, textFormatting, partIndex);
        } else {
            body = buildPlainAttributed(message, partIndex);
        }
    }
    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;

    NSRange zeroRange = NSMakeRange(0, body.length);
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    // Reply targets need a derived thread identifier on macOS 26 to render
    // as a threaded in-line reply rather than a standalone message.
    // Best-effort: if we can't derive the parent, retain the older associated-message
    // fallback so receivers can still render a quoted reply.
    id parentMessage = nil;
    id parentItem = nil;
    NSString *threadIdentifier = nil;
    if (selectedMessageGuid.length) {
        threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                  &parentMessage,
                                                  &parentItem);
        debugLog(@"handleSendMessage: parent=%@ threadId=%@",
                 selectedMessageGuid, threadIdentifier ?: @"(none)");
    } else {
        clearThreadContextForChat(chat, nil);
    }

    NSString *richLinkSnapshotPath = nil;
    IMFileTransfer *richLinkTransfer = nil;
    BOOL richLinkTransferRegistered = NO;
    @try {
        id imMessage = nil;
        BOOL richLinkImageUsed = NO;
        if (richLinkPreview) {
            NSString *urlError = nil;
            NSURL *originalURL = validatedRichLinkURL(richLinkPreview[@"originalURL"], &urlError);
            if (!originalURL || ![message isEqualToString:originalURL.absoluteString]) {
                return errorResponse(requestId,
                    urlError.length ? urlError : @"Rich-link body does not match its URL");
            }
            body = annotateBodyForRichLink(body, originalURL.absoluteString);
            if (!body) {
                return errorResponse(requestId, @"Could not annotate rich-link body");
            }

            NSMutableArray *fileTransferGuids = [NSMutableArray array];
            NSString *previewMimeType = nil;
            NSURL *previewFile = nil;
            NSString *imageError = nil;
            NSDictionary *imageDescriptor = [richLinkPreview[@"image"]
                isKindOfClass:[NSDictionary class]] ? richLinkPreview[@"image"] : nil;
            if (richLinkPreview[@"image"] && !imageDescriptor) {
                return errorResponse(requestId, @"Invalid rich-link image descriptor");
            }
            if (!validateRichLinkPreviewImage(imageDescriptor,
                                              &previewFile,
                                              &previewMimeType,
                                              &imageError)) {
                return errorResponse(requestId, imageError ?: @"Invalid rich-link image");
            }
            if (previewFile) {
                richLinkSnapshotPath = previewFile.path;
                NSString *prepErr = nil;
                NSString *filename = previewFile.lastPathComponent;
                richLinkTransfer = prepareUnregisteredOutgoingTransfer(previewFile,
                                                                       filename,
                                                                       chatGuid,
                                                                       YES,
                                                                       previewMimeType,
                                                                       &prepErr);
                NSString *transferGuid = [richLinkTransfer guid];
                if (transferGuid.length) {
                    [fileTransferGuids addObject:transferGuid];
                    debugLog(@"rich-link: prepared hidden preview transfer");
                } else {
                    debugLog(@"rich-link: hidden preview unavailable (%@); using metadata-only card",
                             prepErr ?: @"unknown");
                    removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                    richLinkSnapshotPath = nil;
                    richLinkTransfer = nil;
                }
            }
            NSString *payloadError = nil;
            BOOL imageSubstituteInstalled = NO;
            NSData *payloadData = buildURLPreviewPayloadData(richLinkPreview,
                                                             fileTransferGuids.count > 0,
                                                             previewMimeType,
                                                             &imageSubstituteInstalled,
                                                             &payloadError);
            if (!payloadData) {
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                return errorResponse(requestId,
                    payloadError.length ? payloadError : @"Could not build URL preview payload");
            }
            if (fileTransferGuids.count > 0 && !imageSubstituteInstalled) {
                [fileTransferGuids removeAllObjects];
                richLinkTransfer = nil;
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                debugLog(@"rich-link: image substitute unavailable; using metadata-only card");
            }
            NSDictionary *summaryInfo = @{
                @"enc": @YES,
                @"eogcd": @3,
                @"ust": @YES
            };
            imMessage = buildBalloonIMMessage(urlPreviewBalloonBundleIdentifier(),
                                              body,
                                              payloadData,
                                              summaryInfo,
                                              fileTransferGuids,
                                              threadIdentifier,
                                              selectedMessageGuid,
                                              parentMessage && [parentMessage respondsToSelector:@selector(guid)]
                                                ? [parentMessage performSelector:@selector(guid)]
                                                : nil,
                                              nil,
                                              parentItem);
        } else {
            imMessage = buildIMMessage(body, subjectAttr,
                                       effectId,
                                       threadIdentifier,
                                       parentItem,
                                       selectedMessageGuid,
                                       associatedType,
                                       zeroRange,
                                       /*summaryInfo*/ nil,
                                       /*fileTransferGuids*/ @[],
                                       /*isAudio*/ NO,
                                       ddScan,
                                       clientMessageGuid);
        }
        if (!imMessage) {
            removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
            richLinkSnapshotPath = nil;
            return errorResponse(requestId, @"Could not construct IMMessage");
        }
        if (richLinkTransfer) {
            NSString *registrationError = nil;
            if (!registerPreparedTransfer(richLinkTransfer, &registrationError)) {
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                return errorResponse(requestId,
                    registrationError ?: @"Could not register rich-link preview transfer");
            }
            richLinkTransferRegistered = YES;
            richLinkImageUsed = YES;
        }

        // IMCore exposes separate originator types: IMMessageItem wants the
        // parent item during item-first construction, while IMMessage wants
        // the parent message on the wrapped object.
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

        if (clientMessageGuid.length && !reserveTrackedMessageGuid(clientMessageGuid)) {
            return errorResponseWithDisposition(
                requestId,
                @"clientMessageGuid is already reserved by another tracked send",
                @"not_started");
        }

        if (gHasSendMessageReason && ddScan) {
            // Deferred-send path on macOS 13+: sleep 100ms, then call
            // `sendMessage:reason:` so the spam filter can run on the body.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                NSMethodSignature *sig = [chat methodSignatureForSelector:
                    @selector(sendMessage:reason:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(sendMessage:reason:)];
                [inv setTarget:chat];
                __unsafe_unretained id arg = imMessage;
                [inv setArgument:&arg atIndex:2];
                NSInteger reason = 0;
                [inv setArgument:&reason atIndex:3];
                [inv invoke];
            });
        } else {
            dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        }

        NSString *guid = clientMessageGuid.length
            ? clientMessageGuid
            : outgoingMessageGuid(imMessage);
        NSMutableDictionary *response = [@{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"queued": @(ddScan)
        } mutableCopy];
        NSString *serviceName = serviceNameForChat(chat, chatGuid);
        if (serviceName.length) response[@"service"] = serviceName;
        if (richLinkPreview) response[@"richLinkImageUsed"] = @(richLinkImageUsed);
        return successResponse(requestId, response);
    } @catch (NSException *exception) {
        if (!richLinkTransferRegistered) {
            removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
        }
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-message failed: %@", exception.reason]);
    }
}

/// `send-poll`: construct a native Messages Polls extension balloon and send
/// it via IMCore. Payload shape mirrors Apple's Polls extension envelope:
/// archived layout metadata plus a data URL carrying the JSON poll definition.
