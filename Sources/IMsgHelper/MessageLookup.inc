static id findMessageItemInObject(id object,
                                  NSString *messageGuid,
                                  NSMutableSet<NSValue *> *visited,
                                  NSUInteger depth) {
    if (!object || !messageGuid.length || depth > 8) return nil;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    SEL guidSel = @selector(guid);
    if ([object respondsToSelector:guidSel]) {
        id guid = safelyReadObjectSelector(object, guidSel);
        if ([guid isKindOfClass:[NSString class]]
            && [guid isEqualToString:messageGuid]) {
            id normalized = normalizeFoundMessageItem(object);
            if (normalized) return normalized;
        }
    }

    // Threaded replies can sit below a top-level transcript item. Walk both
    // public-ish wrappers and private backing objects, with a small depth cap
    // and identity set so cyclic IMCore graphs cannot recurse forever.
    NSArray<NSString *> *objectSelectors = @[
        @"message", @"messageItem", @"_item", @"_imMessageItem"
    ];
    for (NSString *name in objectSelectors) {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) continue;
        id child = safelyReadObjectSelector(object, sel);
        id match = findMessageItemInObject(child, messageGuid, visited, depth + 1);
        if (match) return match;
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_newChatItems", @"chatItems", @"aggregateAttachmentParts"
    ];
    for (NSString *name in collectionSelectors) {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) continue;
        id children = safelyReadObjectSelector(object, sel);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in (NSArray *)children) {
            id match = findMessageItemInObject(child, messageGuid, visited, depth + 1);
            if (match) return match;
        }
    }
    return nil;
}

static id findMessageItem(IMChat *chat, NSString *messageGuid) {
    if (!chat || !messageGuid.length) {
        return nil;
    }

    // BB-verified macOS 11+ path: block-based load via IMChatHistoryController
    // (returns an IMMessage). Callers want the chat item, so navigate
    // IMMessage → IMMessageItem → first IMMessagePartChatItem via the
    // same accessor walk loadParentFirstChatItem performs.
    id loadedMessage = nil;
    id loadedChatItem = loadParentFirstChatItem(messageGuid, &loadedMessage);
    if (!loadedChatItem && loadedMessage) {
        Class contextClass = NSClassFromString(@"IMMutableChatContext");
        SEL contextSel = NSSelectorFromString(@"chatContextForPinnedChat:");
        id chatContext = safelyReadObjectSelectorWithObject(contextClass, contextSel, chat);
        loadedChatItem = normalizeFoundMessageItemWithChatContext(
            loadedMessage, chatContext);
    }
    if (loadedChatItem) return loadedChatItem;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    id hc = hcClass ? [hcClass performSelector:@selector(sharedInstance)] : nil;
    if (hc && [hc respondsToSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)]) {
        NSMethodSignature *sig = [hc methodSignatureForSelector:
            @selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        [inv setTarget:hc];
        [inv setArgument:&chat atIndex:2];
        NSDate *now = [NSDate date];
        [inv setArgument:&now atIndex:3];
        NSUInteger limit = 100;
        [inv setArgument:&limit atIndex:4];
        BOOL load = YES;
        [inv setArgument:&load atIndex:5];
        [inv invoke];
    }

    // Poll chat.chatItems for the guid for up to 2s. Spinning the current
    // run loop gives IMCore a chance to finish loading requested chat items.
    for (NSInteger attempts = 0; attempts < 20; attempts++) {
        NSArray *items = nil;
        if ([chat respondsToSelector:@selector(chatItems)]) {
            items = [chat performSelector:@selector(chatItems)];
        }
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        for (id item in items) {
            id match = findMessageItemInObject(item, messageGuid, visited, 0);
            if (match) return match;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return nil;
}

static id findMessagePartInObject(id object, NSInteger partIndex) {
    if (!object) return nil;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)object) {
            id match = findMessagePartInObject(child, partIndex);
            if (match) return match;
        }
        return nil;
    }

    id aggregate = safelyReadObjectSelector(
        object, @selector(aggregateAttachmentParts));
    id aggregateMatch = findMessagePartInObject(aggregate, partIndex);
    if (aggregateMatch) return aggregateMatch;

    if ([object respondsToSelector:@selector(index)]) {
        @try {
            if ([(IMMessagePartChatItem *)object index] == partIndex) return object;
        } @catch (__unused NSException *exception) {
        }
        return nil;
    }
    return partIndex == 0 ? object : nil;
}

static id findMessagePart(IMChat *chat, NSString *messageGuid, NSInteger partIndex) {
    id item = findMessageItem(chat, messageGuid);
    if (!item) return nil;

    id messageItem = safelyReadObjectSelector(item, @selector(messageItem));
    if (!messageItem) messageItem = item;

    Class contextClass = NSClassFromString(@"IMMutableChatContext");
    SEL contextSel = NSSelectorFromString(@"chatContextForPinnedChat:");
    id chatContext = safelyReadObjectSelectorWithObject(
        contextClass, contextSel, chat);

    id parts = safelyReadObjectSelector(messageItem, @selector(_newChatItems));
    BOOL partsMissing = !parts
        || ([parts isKindOfClass:[NSArray class]] && ((NSArray *)parts).count == 0);
    if (partsMissing && chatContext) {
        SEL contextItemsSel = NSSelectorFromString(@"_newChatItemsWithChatContext:");
        parts = safelyReadObjectSelectorWithObject(
            messageItem, contextItemsSel, chatContext);
        partsMissing = !parts
            || ([parts isKindOfClass:[NSArray class]] && ((NSArray *)parts).count == 0);
        if (partsMissing) {
            Class partClass = NSClassFromString(@"IMMessagePartChatItem");
            SEL partsSel = NSSelectorFromString(
                @"_newMessagePartsForMessageItem:chatContext:");
            parts = safelyReadObjectSelectorWithTwoObjects(
                partClass, partsSel, messageItem, chatContext);
        }
    }

    return findMessagePartInObject(parts ?: item, partIndex);
}

static BOOL resolveMessagePartTarget(NSString *rawGUID, NSString **guid, NSInteger *partIndex) {
    *guid = rawGUID;
    if ([rawGUID hasPrefix:@"p:"]) {
        NSRange slash = [rawGUID rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location <= 2
            || slash.location + 1 >= rawGUID.length) return NO;
        NSString *digits = [rawGUID substringWithRange:NSMakeRange(2, slash.location - 2)];
        if ([digits rangeOfCharacterFromSet:
                [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return NO;
        NSScanner *scanner = [NSScanner scannerWithString:digits];
        if (![scanner scanInteger:partIndex] || !scanner.isAtEnd || *partIndex < 0) return NO;
        *guid = [rawGUID substringFromIndex:slash.location + 1];
    }
    return *partIndex >= 0 && ![*guid containsString:@"/"];
}

// Chat history can still point at the previous send, especially before deferred dispatch.
static NSString *outgoingMessageGuid(id message) {
    id guid = safelyReadObjectSelector(message, @selector(guid));
    return [guid isKindOfClass:[NSString class]] && [guid length] ? guid : nil;
}

#pragma mark - v2 Response Helpers

/// Build a v2-shaped success envelope: { v:2, id, success:true, data:{...} }
static NSDictionary* successResponseV2(NSString *uuid, NSDictionary *data) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @YES,
        @"data": data ?: @{},
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

/// Build a v2-shaped error envelope.
static NSDictionary* errorResponseV2(NSString *uuid, NSString *error) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

static NSDictionary* errorResponseV2WithDisposition(NSString *uuid,
                                                     NSString *error,
                                                     NSString *disposition) {
    NSMutableDictionary *response = [errorResponseV2(uuid, error) mutableCopy];
    if (disposition.length) response[@"delivery_disposition"] = disposition;
    return response;
}

