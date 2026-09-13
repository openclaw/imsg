#pragma mark - Mutate Handlers (v2)

/// `edit-message`: rewrite an existing message via the edit selector
/// appropriate for the running macOS. Preserves BB's "Compatability" typo.
static NSDictionary *handleEditMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSString *newText = params[@"editedMessage"];
    NSString *bcText = params[@"backwardsCompatibilityMessage"]
                     ?: params[@"backwardCompatibilityMessage"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");
    if (!newText.length) return errorResponse(requestId, @"Missing editedMessage");
    if (!bcText) bcText = newText;

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasEditMessageItemTranslation && !gHasEditMessageItem && !gHasEditMessage) {
        return errorResponse(requestId, @"No edit-message selector available on this macOS");
    }

    NSAttributedString *newBody = buildPlainAttributed(newText, partIndex);
    // backwardCompatabilityText: must be an NSAttributedString; passing a plain
    // NSString makes editMessageItem: silently bail (no edit, no error).
    NSAttributedString *bcBody = [[NSAttributedString alloc] initWithString:bcText];

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }

    @try {
        NSInteger localPartIndex = partIndex;
        if (gHasEditMessageItemTranslation) {
            // macOS 26 path: editMessageItem: gained a newPartTranslation: parameter
            // inserted before backwardCompatabilityText:. The pre-26 selectors below
            // no longer exist on Tahoe, so without this branch edit silently reports
            // "no selector available". Pass nil translation (no localized override).
            id messageItem = [item respondsToSelector:@selector(messageItem)]
                ? [item performSelector:@selector(messageItem)] : item;
            SEL sel = @selector(editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id ci = messageItem;
            [inv setArgument:&ci atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            id translationArg = nil;
            [inv setArgument:&translationArg atIndex:5];
            __unsafe_unretained NSAttributedString *bcArg = bcBody;
            [inv setArgument:&bcArg atIndex:6];
            [inv invoke];
        } else if (gHasEditMessageItem) {
            // editMessageItem: takes the IMMessageItem, not the chat item.
            // findMessageItem returns an IMMessagePartChatItem; reach the
            // backing item via -messageItem.
            id messageItem = [item respondsToSelector:@selector(messageItem)]
                ? [item performSelector:@selector(messageItem)] : item;
            SEL sel = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id ci = messageItem;
            [inv setArgument:&ci atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSAttributedString *bcArg = bcBody;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        } else {
            // macOS 13 path
            SEL sel = @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:);
            id message = nil;
            if ([item respondsToSelector:@selector(message)]) {
                message = [item performSelector:@selector(message)];
            }
            if (!message) {
                return errorResponse(requestId,
                    [NSString stringWithFormat:@"Message object not found: %@", messageGuid]);
            }
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id msg = message;
            [inv setArgument:&msg atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSAttributedString *bcArg = bcBody;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"edit-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `unsend-message`: retract a part of a sent message via retractMessagePart:.
static NSDictionary *handleUnsendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasRetractMessagePart) {
        return errorResponse(requestId, @"retractMessagePart: not available on this macOS");
    }

    id target = findMessagePart(chat, messageGuid, partIndex);
    if (!target) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message part not found: %ld", (long)partIndex]);
    }

    @try {
        [chat performSelector:@selector(retractMessagePart:) withObject:target];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"unsend-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `delete-message`: remove a single message from the chat.
static NSDictionary *handleDeleteMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    SEL sel = @selector(deleteChatItems:);
    if (![chat respondsToSelector:sel]) {
        return errorResponse(requestId, @"deleteChatItems: not available");
    }

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }
    @try {
        [chat performSelector:sel withObject:@[item]];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"delete-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
    });
}

