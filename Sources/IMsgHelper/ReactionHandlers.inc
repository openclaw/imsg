static NSDictionary *handleSendReaction(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSString *reactionType = params[@"reactionType"];
    NSString *emoji = params[@"emoji"];
    BOOL removeEmoji = [params[@"remove"] boolValue];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!selectedMessageGuid.length) return errorResponse(requestId, @"Missing selectedMessageGuid");
    if (!emoji.length && !reactionType.length) {
        return errorResponse(requestId, @"Missing reactionType");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    // Arbitrary emoji tapbacks (iOS 18+) are stored as associated_message_type
    // 2006/3006 with the emoji in associated_message_emoji, and they do not fit
    // the six-kind whitelist below. IMEmojiTapback + IMTapbackSender is the
    // private path Messages itself uses; the classic IMMessage constructor
    // cannot carry associatedMessageEmoji, so a custom emoji sent through it is
    // refused with "Unknown reactionType" (the bug this branch fixes).
    if (emoji.length) {
        id parentMsg = nil;
        id parentChatItem = loadParentFirstChatItem(selectedMessageGuid, &parentMsg);
        NSString *parentText = nil;
        if (parentMsg && [parentMsg respondsToSelector:@selector(text)]) {
            id t = [parentMsg performSelector:@selector(text)];
            if ([t isKindOfClass:[NSAttributedString class]]) {
                parentText = [(NSAttributedString *)t string];
            }
        }
        NSRange targetRange = NSMakeRange(0, 1);
        if (parentChatItem
            && [parentChatItem respondsToSelector:@selector(messagePartRange)]) {
            targetRange = [(IMMessagePartChatItem *)parentChatItem messagePartRange];
            if (targetRange.length == 0) targetRange = NSMakeRange(0, 1);
        }
        NSDictionary *emojiSummary = @{ @"amc": @1,
                                        @"ams": parentText ?: @"" };

        @try {
            Class tapbackClass = NSClassFromString(@"IMEmojiTapback");
            Class senderClass = NSClassFromString(@"IMTapbackSender");
            SEL tapbackInitSel = NSSelectorFromString(@"initWithEmoji:isRemoved:");
            NSMethodSignature *tsig = tapbackClass
                ? [tapbackClass instanceMethodSignatureForSelector:tapbackInitSel] : nil;
            if (!tsig) {
                return errorResponse(requestId,
                    @"Emoji tapbacks unsupported on this macOS version");
            }

            id tapback = [tapbackClass alloc];
            NSInvocation *tinv = [NSInvocation invocationWithMethodSignature:tsig];
            [tinv setSelector:tapbackInitSel];
            [tinv setTarget:tapback];
            [tinv setArgument:&emoji atIndex:2];
            [tinv setArgument:&removeEmoji atIndex:3];
            [tinv retainArguments];
            tapback = invokeReturningObject(tinv);
            if (!tapback) {
                return errorResponse(requestId, @"Could not construct IMEmojiTapback");
            }

            SEL senderPartSel =
                NSSelectorFromString(@"initWithTapback:chat:messagePartChatItem:");
            SEL senderRangeSel = NSSelectorFromString(
                @"initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:");
            id sender = nil;
            if (parentChatItem && [senderClass instancesRespondToSelector:senderPartSel]) {
                NSMethodSignature *ssig =
                    [senderClass instanceMethodSignatureForSelector:senderPartSel];
                NSInvocation *sinv = [NSInvocation invocationWithMethodSignature:ssig];
                [sinv setSelector:senderPartSel];
                [sinv setTarget:[senderClass alloc]];
                [sinv setArgument:&tapback atIndex:2];
                [sinv setArgument:&chat atIndex:3];
                [sinv setArgument:&parentChatItem atIndex:4];
                [sinv retainArguments];
                sender = invokeReturningObject(sinv);
            } else if ([senderClass instancesRespondToSelector:senderRangeSel]) {
                NSMethodSignature *ssig =
                    [senderClass instanceMethodSignatureForSelector:senderRangeSel];
                NSInvocation *sinv = [NSInvocation invocationWithMethodSignature:ssig];
                [sinv setSelector:senderRangeSel];
                [sinv setTarget:[senderClass alloc]];
                [sinv setArgument:&tapback atIndex:2];
                [sinv setArgument:&chat atIndex:3];
                [sinv setArgument:&selectedMessageGuid atIndex:4];
                [sinv setArgument:&targetRange atIndex:5];
                [sinv setArgument:&emojiSummary atIndex:6];
                id nilThreadId = nil;
                [sinv setArgument:&nilThreadId atIndex:7];
                [sinv retainArguments];
                sender = invokeReturningObject(sinv);
            }
            if (!sender || ![sender respondsToSelector:@selector(send)]) {
                return errorResponse(requestId, @"Could not construct IMTapbackSender");
            }

            [sender performSelector:@selector(send)];
            debugLog(@"handleSendReaction: emoji %@ dispatched (remove=%d)",
                     emoji, removeEmoji);
            // IMTapbackSender dispatches the reaction without surfacing the
            // sent message's guid, and the older lastSentMessageGuid(chat)
            // helper is gone (native sends now carry their own identity). The
            // reaction is already on its way, so report success without
            // claiming a guid we cannot read.
            return successResponse(requestId, @{
                @"chatGuid": chatGuid,
                @"selectedMessageGuid": selectedMessageGuid,
                @"emoji": emoji,
                @"messageGuid": @""
            });
        } @catch (NSException *exception) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"send-reaction (emoji) failed: %@",
                    exception.reason]);
        }
    }

    long long associatedType = -1;
    NSDictionary *kindMap = @{
        @"love": @2000, @"like": @2001, @"dislike": @2002,
        @"laugh": @2003, @"emphasize": @2004, @"question": @2005,
        @"remove-love": @3000, @"remove-like": @3001, @"remove-dislike": @3002,
        @"remove-laugh": @3003, @"remove-emphasize": @3004, @"remove-question": @3005,
    };
    NSNumber *typeNum = kindMap[reactionType.lowercaseString];
    if (typeNum) associatedType = [typeNum longLongValue];
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
        id imMessage = buildIMMessage(body, nil, nil, nil,
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
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"selectedMessageGuid": selectedMessageGuid,
            @"reactionType": reactionType,
            @"messageGuid": guid ?: @""
        });
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

