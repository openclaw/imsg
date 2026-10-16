static SEL emojiTapbackMessageSelector(void) {
    return @selector(instantMessageWithAssociatedMessageContent:associatedMessageGUID:associatedMessageType:associatedMessageRange:associatedMessageEmoji:messageSummaryInfo:threadIdentifier:);
}

static BOOL emojiTapbackMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    return messageClass && [messageClass respondsToSelector:emojiTapbackMessageSelector()];
}

// Custom emoji tapbacks (2006/3006) need associatedMessageEmoji, which the
// classic reaction initializers in buildIMMessage can't carry.
static id buildEmojiTapbackMessage(NSAttributedString *body,
                                   NSString *associatedMessageGuid,
                                   long long associatedMessageType,
                                   NSRange associatedMessageRange,
                                   NSString *emoji,
                                   NSDictionary *summaryInfo) {
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL sel = emojiTapbackMessageSelector();
    NSMethodSignature *sig = [messageClass methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:messageClass];
    id threadIdentifier = nil;
    [inv setArgument:&body atIndex:2];
    [inv setArgument:&associatedMessageGuid atIndex:3];
    [inv setArgument:&associatedMessageType atIndex:4];
    [inv setArgument:&associatedMessageRange atIndex:5];
    [inv setArgument:&emoji atIndex:6];
    [inv setArgument:&summaryInfo atIndex:7];
    [inv setArgument:&threadIdentifier atIndex:8];
    [inv retainArguments];
    return invokeReturningObject(inv);
}

static NSDictionary *handleSendReaction(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSString *reactionType = params[@"reactionType"];
    NSString *emoji = params[@"emoji"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!selectedMessageGuid.length) return errorResponse(requestId, @"Missing selectedMessageGuid");
    if (!reactionType.length && !emoji.length) {
        return errorResponse(requestId, @"Missing reactionType or emoji");
    }
    if (reactionType.length && emoji.length) {
        return errorResponse(requestId, @"Pass reactionType or emoji, not both");
    }
    if (emoji.length && !emojiTapbackMessageInitializerAvailable()) {
        return errorResponse(requestId, @"Emoji tapback IMMessage initializer unavailable on this macOS");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    long long associatedType = -1;
    NSDictionary *kindMap = @{
        @"love": @2000, @"like": @2001, @"dislike": @2002,
        @"laugh": @2003, @"emphasize": @2004, @"question": @2005,
        @"remove-love": @3000, @"remove-like": @3001, @"remove-dislike": @3002,
        @"remove-laugh": @3003, @"remove-emphasize": @3004, @"remove-question": @3005,
    };
    NSNumber *typeNum = kindMap[reactionType.lowercaseString];
    if (emoji.length) {
        associatedType = [params[@"remove"] boolValue] ? 3006 : 2006;
    } else if (typeNum) {
        associatedType = [typeNum longLongValue];
    }
    if (associatedType <= 0) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Unknown reactionType: %@", reactionType]);
    }

    NSString *targetGUID = nil;
    // Embedded parts already take precedence over the wrappers' default partIndex=0.
    if (!resolveMessagePartTarget(selectedMessageGuid, &targetGUID, &partIndex)) {
        return errorResponse(requestId, @"Malformed reaction target");
    }
    NSString *associatedRef = [NSString stringWithFormat:@"p:%ld/%@", (long)partIndex, targetGUID];

    // Reaction body needs the verb-style summary text — `Loved "parent
    // text"` — not an empty string. imagent silently drops reactions with
    // empty body. Best-effort: load the parent and quote its text; fall
    // back to a generic phrase if we can't resolve it.
    NSString *verb = @"Loved ";
    switch (associatedType) {
        case 2000: case 3000: verb = @"Loved "; break;
        case 2001: case 3001: verb = @"Liked "; break;
        case 2002: case 3002: verb = @"Disliked "; break;
        case 2003: case 3003: verb = @"Laughed at "; break;
        case 2004: case 3004: verb = @"Emphasized "; break;
        case 2005: case 3005: verb = @"Questioned "; break;
        case 2006: verb = [NSString stringWithFormat:@"Reacted %@ to ", emoji]; break;
    }
    if (associatedType >= 3000) {
        NSString *removed = @"Removed a like from ";
        switch (associatedType) {
            case 3000: removed = @"Removed a heart from "; break;
            case 3001: removed = @"Removed a like from "; break;
            case 3002: removed = @"Removed a dislike from "; break;
            case 3003: removed = @"Removed a laugh from "; break;
            case 3004: removed = @"Removed an exclamation from "; break;
            case 3005: removed = @"Removed a question mark from "; break;
            case 3006: removed = [NSString stringWithFormat:@"Removed %@ from ", emoji]; break;
        }
        verb = removed;
    }
    id parentChatItem = findMessagePart(chat, targetGUID, partIndex);
    if (!parentChatItem && partIndex != 0) {
        return errorResponse(requestId, @"Reaction message part not found");
    }
    id text = safelyReadObjectSelector(parentChatItem, @selector(text));
    NSString *parentText = [text isKindOfClass:[NSAttributedString class]]
        ? [text string] : ([text isKindOfClass:[NSString class]] ? text : nil);
    // The reference and range must identify the same part, including attachment grids.
    NSRange targetRange = NSMakeRange(0, 1);
    if (parentChatItem
        && [parentChatItem respondsToSelector:@selector(messagePartRange)]) {
        targetRange = [(IMMessagePartChatItem *)parentChatItem messagePartRange];
        if (targetRange.length == 0) targetRange = NSMakeRange(0, 1);
    }
    NSString *quoted = parentText.length
        ? [NSString stringWithFormat:@"%@“%@”", verb, parentText]
        : [verb stringByAppendingString:@"a message"];
    NSAttributedString *body = buildPlainAttributed(quoted, partIndex);

    // BB-verified `messageSummaryInfo` shape: `amc` is an integer count
    // (always `@1` for single-target tapbacks), `ams` is the parent text
    // (the receiver's notification preview reads `<verb> "<ams>"`). Earlier
    // we were stuffing the parent guid into `amc` as a string — the
    // resulting `message_summary_info` blob was malformed and on macOS 26
    // imagent silently dropped the reaction.
    NSDictionary *summary = @{ @"amc": @1,
                               @"ams": parentText ?: @"" };
    debugLog(@"handleSendReaction: target=%@ type=%lld range={%lu,%lu} body=%@",
             associatedRef, associatedType,
             (unsigned long)targetRange.location, (unsigned long)targetRange.length,
             quoted);

    @try {
        id imMessage = emoji.length
            ? buildEmojiTapbackMessage(body, associatedRef, associatedType,
                                       targetRange, emoji, summary)
            : buildIMMessage(body, nil, nil, nil,
                             nil,
                             associatedRef,
                             associatedType,
                             targetRange,
                             summary,
                             @[], NO, NO, nil);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build reaction IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        debugLog(@"handleSendReaction: dispatched");
        NSString *guid = outgoingMessageGuid(imMessage);
        NSMutableDictionary *result = [@{
            @"chatGuid": chatGuid,
            @"selectedMessageGuid": selectedMessageGuid,
            @"messageGuid": guid ?: @""
        } mutableCopy];
        result[@"reactionType"] = reactionType;
        result[@"emoji"] = emoji;
        return successResponse(requestId, result);
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-reaction failed: %@", exception.reason]);
    }
}

/// `notify-anyways`: ask Messages.app to deliver a low-priority notification
/// for a previously-suppressed message guid.
static NSDictionary *handleNotifyAnyways(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    @try {
        // BB-verified macOS 12+ path: `markChatItemAsNotifyRecipient:` is
        // the focus-bypass primitive ("Notify Anyway" UI affordance). Our
        // previous `sendMessageAcknowledgment:forChatItem:withMessageSummaryInfo:withGuid:`
        // with ack=1000 was actually a tapback ack, not a notify-anyway —
        // wrong operation entirely.
        SEL sel = @selector(markChatItemAsNotifyRecipient:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"markChatItemAsNotifyRecipient: not available");
        }
        id item = findMessageItem(chat, messageGuid);
        if (!item) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
        }
        [chat performSelector:sel withObject:item];
        return successResponse(requestId, @{
            @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"notify-anyways failed: %@", exception.reason]);
    }
}

