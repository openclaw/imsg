static NSDictionary *handleSendMultipart(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSArray *parts = params[@"parts"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) {
        return errorResponse(requestId, @"Missing or empty parts array");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSInteger partIndex = 0;
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = part[@"text"];
        if (!text.length) continue;
        NSArray *partFormatting = part[@"textFormatting"];
        NSAttributedString *seg;
        if ([partFormatting isKindOfClass:[NSArray class]] && partFormatting.count > 0) {
            seg = buildFormattedAttributed(text, partFormatting, partIndex);
        } else {
            seg = buildPlainAttributed(text, partIndex);
        }
        [body appendAttributedString:seg];
        partIndex++;
    }
    if (body.length == 0) {
        return errorResponse(requestId, @"No usable parts");
    }

    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    @try {
        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendMultipart: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }
        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length),
                                      nil, @[], NO, NO, nil);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct multipart IMMessage");
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
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"parts_count": @(partIndex)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
}

/// Build an attachment-bearing attributed string. The placeholder is an OBJ
/// replacement character (￼) tagged with the IMCore attachment attributes
/// (`__kIMFileTransferGUIDAttributeName`, `__kIMFilenameAttributeName`,
/// `__kIMMessagePartAttributeName`, `__kIMBaseWritingDirectionAttributeName`).
/// Without these attributes Messages.app sends an empty-body message and never
/// links the attachment row in chat.db.
static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex) {
    NSDictionary *attrs = @{
        @"__kIMBaseWritingDirectionAttributeName": @"-1",
        @"__kIMFileTransferGUIDAttributeName": transferGuid ?: @"",
        @"__kIMFilenameAttributeName": filename ?: @"",
        @"__kIMMessagePartAttributeName": @(partIndex),
    };
    return [[NSAttributedString alloc] initWithString:@"￼" attributes:attrs];
}

static void setIntegerProperty(id object, SEL selector, NSInteger value) {
    if (!object || ![object respondsToSelector:selector]) return;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:selector];
    [inv setTarget:object];
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}

