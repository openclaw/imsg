static NSString *deriveThreadIdentifier(NSString *parentGuid,
                                         id *outParentMessage,
                                         id *outParentItem) {
    if (outParentMessage) *outParentMessage = nil;
    if (outParentItem) *outParentItem = nil;
    if (parentGuid.length == 0) return nil;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    if (!hcClass) {
        debugLog(@"deriveThreadIdentifier: IMChatHistoryController class missing");
        return nil;
    }
    id hc = [hcClass performSelector:@selector(sharedInstance)];
    if (!hc) {
        debugLog(@"deriveThreadIdentifier: sharedInstance returned nil");
        return nil;
    }
    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![hc respondsToSelector:loadSel]) {
        debugLog(@"deriveThreadIdentifier: loadMessageWithGUID:completionBlock: missing");
        return nil;
    }

    __block id parent = nil;
    __block BOOL done = NO;
    NSMethodSignature *sig = [hc methodSignatureForSelector:loadSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:loadSel];
    [inv setTarget:hc];
    NSString *guid = parentGuid;
    [inv setArgument:&guid atIndex:2];
    void (^completion)(id) = ^(id message) {
        parent = message;
        done = YES;
    };
    [inv setArgument:&completion atIndex:3];
    [inv retainArguments];
    [inv invoke];

    // Pump the run loop briefly so the load completion can run inline.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!parent) {
        debugLog(@"deriveThreadIdentifier: parent did not load within 3s for %@",
                 parentGuid);
        return nil;
    }
    if (outParentMessage) *outParentMessage = parent;

    if (![parent respondsToSelector:@selector(_imMessageItem)]) {
        debugLog(@"deriveThreadIdentifier: parent has no _imMessageItem");
        return nil;
    }
    id parentItem = [parent performSelector:@selector(_imMessageItem)];
    if (outParentItem) *outParentItem = parentItem;

    SEL chatItemsSel = NSSelectorFromString(@"_newChatItems");
    if (!parentItem || ![parentItem respondsToSelector:chatItemsSel]) {
        debugLog(@"deriveThreadIdentifier: parentItem missing _newChatItems");
        return nil;
    }

    id items = [parentItem performSelector:chatItemsSel];
    id chatItem = nil;
    if ([items isKindOfClass:[NSArray class]]) {
        SEL backingItemSel = NSSelectorFromString(@"_item");
        for (id candidate in (NSArray *)items) {
            id backingItem = [candidate respondsToSelector:backingItemSel]
                ? [candidate performSelector:backingItemSel] : nil;
            NSString *candidateGuid = nil;
            if ([backingItem respondsToSelector:@selector(guid)]) {
                candidateGuid = [backingItem performSelector:@selector(guid)];
            } else if ([candidate respondsToSelector:@selector(guid)]) {
                candidateGuid = [candidate performSelector:@selector(guid)];
            }
            if ([candidateGuid isEqualToString:parentGuid]) {
                chatItem = candidate;
                break;
            }
        }
        if (!chatItem) {
            chatItem = [(NSArray *)items firstObject];
        }
    } else {
        chatItem = items;
    }
    if (!chatItem) {
        debugLog(@"deriveThreadIdentifier: parent has no chat items");
        return nil;
    }

    if ([parent respondsToSelector:@selector(threadIdentifier)]) {
        NSString *existingIdentifier =
            [parent performSelector:@selector(threadIdentifier)];
        if (existingIdentifier.length > 0) {
            debugLog(@"deriveThreadIdentifier: parent=%@ existing=%@",
                     parentGuid, existingIdentifier);
            return existingIdentifier;
        }
    }

    IMCreateThreadIdentifierForMessagePartChatItemFn fn =
        imCreateThreadIdentifierFn();
    if (!fn) {
        debugLog(@"deriveThreadIdentifier: IMCreateThreadIdentifier… symbol not found");
        return nil;
    }
    NSString *result = fn(chatItem);
    debugLog(@"deriveThreadIdentifier: parent=%@ result=%@",
             parentGuid, result ?: @"(nil)");
    return result;
}

/// Load the parent message via `IMChatHistoryController` and return its
/// first `IMMessagePartChatItem` plus the parent message itself. Used by
/// reactions to derive the canonical `associatedMessageRange` (BB-verified:
/// `[item messagePartRange]`, not a hardcoded `{0,1}`).
///
/// Block-based load semantics match `loadMessageWithGUID:completionBlock:`,
/// which `deriveThreadIdentifier` already drives. This helper duplicates
/// the load to keep the reply / reaction code paths independent (each
/// fires its own load), which is what BlueBubblesHelper does too — and
/// avoids gnarly out-parameter plumbing through deriveThreadIdentifier.
static id safelyReadObjectSelector(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        // Some Tahoe IMCore proxy objects claim private selectors through
        // forwarding, then raise unrecognized-selector when invoked.
        return nil;
    }
}

static id safelyReadObjectSelectorWithObject(id object, SEL selector, id argument) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id safelyReadObjectSelectorWithTwoObjects(id object, SEL selector,
                                                 id first, id second) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)(
            object, selector, first, second);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id normalizeFoundMessageItemWithChatContext(id object, id chatContext) {
    if (!object) return nil;

    Class partClass = NSClassFromString(@"IMMessagePartChatItem");
    if (partClass && [object isKindOfClass:partClass]) return object;

    // History loading can yield an IMMessage, its backing IMMessageItem, or
    // a chat item directly depending on OS version and whether it is a
    // threaded reply. Normalize all three to the chat item mutations expect.
    id messageItem = object;
    SEL itemSel = @selector(_imMessageItem);
    if ([messageItem respondsToSelector:itemSel]) {
        messageItem = safelyReadObjectSelector(messageItem, itemSel);
        if (!messageItem) return nil;
    }
    SEL chatItemsSel = @selector(_newChatItems);
    BOOL hasChatItemsSelector = [messageItem respondsToSelector:chatItemsSel];
    id items = nil;
    if (hasChatItemsSelector) {
        items = safelyReadObjectSelector(messageItem, chatItemsSel);
    }
    BOOL needsContext = !items
        || ([items isKindOfClass:[NSArray class]] && ((NSArray *)items).count == 0);
    if (needsContext && chatContext) {
        SEL contextSel = NSSelectorFromString(@"_newChatItemsWithChatContext:");
        items = safelyReadObjectSelectorWithObject(messageItem, contextSel, chatContext);
        BOOL contextItemsMissing = !items
            || ([items isKindOfClass:[NSArray class]] && ((NSArray *)items).count == 0);
        if (contextItemsMissing) {
            SEL partsSel = NSSelectorFromString(
                @"_newMessagePartsForMessageItem:chatContext:");
            items = safelyReadObjectSelectorWithTwoObjects(
                partClass, partsSel, messageItem, chatContext);
        }
    }
    if ([items isKindOfClass:[NSArray class]]) {
        return ((NSArray *)items).firstObject;
    }
    return items ?: (hasChatItemsSelector ? nil : messageItem);
}

static id normalizeFoundMessageItem(id object) {
    return normalizeFoundMessageItemWithChatContext(object, nil);
}

static id loadParentFirstChatItem(NSString *parentGuid, id *outParentMessage) {
    if (outParentMessage) *outParentMessage = nil;
    if (parentGuid.length == 0) return nil;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    if (!hcClass) return nil;
    id hc = [hcClass performSelector:@selector(sharedInstance)];
    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (!hc || ![hc respondsToSelector:loadSel]) return nil;

    __block id parent = nil;
    __block BOOL done = NO;
    NSMethodSignature *sig = [hc methodSignatureForSelector:loadSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:loadSel];
    [inv setTarget:hc];
    NSString *guid = parentGuid;
    [inv setArgument:&guid atIndex:2];
    void (^completion)(id) = ^(id m) { parent = m; done = YES; };
    [inv setArgument:&completion atIndex:3];
    [inv retainArguments];
    [inv invoke];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!parent) return nil;
    if (outParentMessage) *outParentMessage = parent;
    return normalizeFoundMessageItem(parent);
}

/// Dispatch a built IMMessage into the chat after installing the same
/// thread context Messages.app keeps for inline replies. The private
/// `_sendMessage:adjustingSender:shouldQueue:` path we tried earlier may
/// silently drop items in some macOS 26 states, so use the chat registry
/// dispatch when available and fall back to `-[IMChat sendMessage:]`.
static void prepareThreadContextForSend(IMChat *chat,
                                        NSString *threadIdentifier,
                                        id threadOriginator) {
    if (!chat) return;
    if ([chat respondsToSelector:@selector(inlineReplyController)]) {
        id controller = [chat performSelector:@selector(inlineReplyController)];
        if ([controller respondsToSelector:@selector(setThreadIdentifier:)]) {
            [controller performSelector:@selector(setThreadIdentifier:)
                             withObject:(threadIdentifier.length ? threadIdentifier : nil)];
        }
        if ([controller respondsToSelector:@selector(setThreadOriginator:)]) {
            [controller performSelector:@selector(setThreadOriginator:)
                             withObject:threadOriginator];
        }
    }

    NSString *chatGUID = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : nil;
    if (!chatGUID.length) return;

    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    if (!registry) {
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass && [registryClass respondsToSelector:@selector(sharedInstance)]) {
            registry = [registryClass performSelector:@selector(sharedInstance)];
        }
    }
    if (!registry
        || ![registry respondsToSelector:@selector(chatGUIDToCurrentThreadMap)]) {
        return;
    }

    id map = [registry performSelector:@selector(chatGUIDToCurrentThreadMap)];
    if (![map isKindOfClass:[NSMutableDictionary class]]) return;
    if (threadIdentifier.length) {
        [(NSMutableDictionary *)map setObject:threadIdentifier forKey:chatGUID];
    } else {
        [(NSMutableDictionary *)map removeObjectForKey:chatGUID];
    }
}

static void clearThreadContextForChat(IMChat *chat, NSString *expectedThreadIdentifier) {
    if (!chat) return;
    if ([chat respondsToSelector:@selector(inlineReplyController)]) {
        id controller = [chat performSelector:@selector(inlineReplyController)];
        BOOL shouldClearController = YES;
        if (expectedThreadIdentifier.length
            && [controller respondsToSelector:@selector(threadIdentifier)]) {
            NSString *current =
                [controller performSelector:@selector(threadIdentifier)];
            shouldClearController =
                !current.length || [current isEqualToString:expectedThreadIdentifier];
        }
        if (shouldClearController) {
            if ([controller respondsToSelector:@selector(setThreadIdentifier:)]) {
                [controller performSelector:@selector(setThreadIdentifier:)
                                 withObject:nil];
            }
            if ([controller respondsToSelector:@selector(setThreadOriginator:)]) {
                [controller performSelector:@selector(setThreadOriginator:)
                                 withObject:nil];
            }
        }
    }

    NSString *chatGUID = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : nil;
    if (!chatGUID.length) return;

    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    if (!registry) {
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass && [registryClass respondsToSelector:@selector(sharedInstance)]) {
            registry = [registryClass performSelector:@selector(sharedInstance)];
        }
    }
    if (!registry
        || ![registry respondsToSelector:@selector(chatGUIDToCurrentThreadMap)]) {
        return;
    }

    id map = [registry performSelector:@selector(chatGUIDToCurrentThreadMap)];
    if (![map isKindOfClass:[NSMutableDictionary class]]) return;
    NSString *current = [(NSMutableDictionary *)map objectForKey:chatGUID];
    if (!expectedThreadIdentifier.length
        || !current.length
        || [current isEqualToString:expectedThreadIdentifier]) {
        [(NSMutableDictionary *)map removeObjectForKey:chatGUID];
    }
}

static void scheduleThreadContextClear(IMChat *chat, NSString *threadIdentifier) {
    if (!chat) return;
    NSString *expected = threadIdentifier ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        clearThreadContextForChat(chat, expected);
    });
}

static void dispatchIMMessageInChat(IMChat *chat,
                                    id message,
                                    NSString *threadIdentifier,
                                    id threadOriginator) {
    if (!threadIdentifier.length) {
        clearThreadContextForChat(chat, nil);
        clearReplyMetadataOnMessage(message);
        [chat performSelector:@selector(sendMessage:) withObject:message];
        return;
    }

    prepareThreadContextForSend(chat, threadIdentifier, threadOriginator);
    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    SEL registrySendSel = NSSelectorFromString(@"_chat:sendMessage:");
    if (registry && [registry respondsToSelector:registrySendSel]) {
        NSMethodSignature *sig = [registry methodSignatureForSelector:registrySendSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:registrySendSel];
        [inv setTarget:registry];
        __unsafe_unretained id chatArg = chat;
        __unsafe_unretained id messageArg = message;
        [inv setArgument:&chatArg atIndex:2];
        [inv setArgument:&messageArg atIndex:3];
        [inv invoke];
        scheduleThreadContextClear(chat, threadIdentifier);
        return;
    }
    [chat performSelector:@selector(sendMessage:) withObject:message];
    scheduleThreadContextClear(chat, threadIdentifier);
}

