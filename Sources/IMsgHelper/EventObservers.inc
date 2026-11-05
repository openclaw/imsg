#pragma mark - Inbound Event Observers

static BOOL chatItemsContainClass(NSArray *items, Class itemClass) {
    NSUInteger index = [items indexOfObjectWithOptions:NSEnumerationReverse
                                           passingTest:^BOOL(id item, NSUInteger idx, BOOL *stop) {
        return [item isKindOfClass:itemClass];
    }];
    return index != NSNotFound;
}

/// IMCore keeps an IMTypingChatItem near the end of a chat's items while
/// someone else is typing. A chat loaded without opening its transcript can
/// still end in a banner such as IMReportSpamChatItem, so look past the last item.
static NSString *typingEventForChatItems(id oldItems, id newItems) {
    if (![oldItems isKindOfClass:[NSArray class]]) return nil;
    if (![newItems isKindOfClass:[NSArray class]]) return nil;
    Class typingItemClass = NSClassFromString(@"IMTypingChatItem");
    if (!typingItemClass) return nil;

    BOOL wasTyping = chatItemsContainClass(oldItems, typingItemClass);
    BOOL isTyping = chatItemsContainClass(newItems, typingItemClass);
    if (wasTyping == isTyping) return nil;
    return isTyping ? @"started-typing" : @"stopped-typing";
}

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
static void registerEventObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:@"__kIMChatItemsDidChangeNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            NSString *event = typingEventForChatItems(note.userInfo[@"__kIMChatItemsOldItems"],
                                                      note.userInfo[@"__kIMChatItemsNewItems"]);
            if (!event) return;

            id chatGuid = safelyReadObjectSelector(note.object, @selector(guid));
            if (![chatGuid isKindOfClass:[NSString class]] || [chatGuid length] == 0) return;
            appendEvent(@{@"event": event, @"data": @{@"chatGuid": chatGuid}});
        }
    }];

    // Account aliases removed (e.g., user removed an iMessage email).
    [nc addObserverForName:@"__kIMAccountAliasesRemovedNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        appendEvent(@{
            @"event": @"aliases-removed",
            @"data": note.userInfo ?: @{}
        });
    }];

    NSLog(@"[imsg-bridge] Event observers registered");
}

