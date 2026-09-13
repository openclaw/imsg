#pragma mark - Inbound Event Observers

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
static void registerEventObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // IMChatItemsDidChange: fires whenever a chat's item list shifts. We
    // inspect the userInfo to spot inserted IMTypingChatItem instances and
    // emit started-typing / stopped-typing events.
    [nc addObserverForName:@"IMChatItemsDidChangeNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            id chat = note.object;
            NSString *chatGuid = nil;
            if (chat && [chat respondsToSelector:@selector(guid)]) {
                chatGuid = [chat performSelector:@selector(guid)];
            }
            NSDictionary *userInfo = note.userInfo;
            NSArray *inserted = userInfo[@"__kIMChatValueKey"]
                              ?: userInfo[@"inserted"];
            if (![inserted isKindOfClass:[NSArray class]]) return;
            for (id item in inserted) {
                NSString *cls = NSStringFromClass([item class]);
                if ([cls containsString:@"TypingChatItem"]) {
                    BOOL isCancel = NO;
                    if ([item respondsToSelector:@selector(isCancelTypingMessage)]) {
                        isCancel = ((BOOL (*)(id, SEL))objc_msgSend)(item,
                            @selector(isCancelTypingMessage));
                    }
                    appendEvent(@{
                        @"event": isCancel ? @"stopped-typing" : @"started-typing",
                        @"data": @{ @"chatGuid": chatGuid ?: @"" }
                    });
                }
            }
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

