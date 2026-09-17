// Non-sending probe using real IMCore classes: make test-native-replies.
// Constructs synthetic messages without resolving a conversation or opening chat.db.
#import "../../Sources/IMsgHelper/IMsgInjected.m"

int main(void) {
    @autoreleasepool {
        void *core = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW);
        if (!core) { fprintf(stderr, "Cannot load IMCore: %s\n", dlerror()); return 2; }
        NSUInteger failures = 0;
        for (NSNumber *scenario in @[@0, @1, @2]) {
            @try {
                BOOL threaded = scenario.integerValue != 0;
                BOOL multipart = scenario.integerValue == 2;
                NSString *thread = threaded
                    ? @"0:0:12:00000000-0000-0000-0000-000000000000" : nil;
                NSMutableAttributedString *body = [buildPlainAttributed(@"Local rendering probe", 0) mutableCopy];
                if (multipart) {
                    [body appendAttributedString:buildFormattedAttributed(@" second part",
                        @[@{@"start": @1, @"length": @6, @"styles": @[@"bold"]}], 1)];
                }
                id message = buildIMMessage(body,
                    nil, nil, thread, nil,
                    threaded ? @"00000000-0000-0000-0000-000000000000" : nil,
                    threaded ? 100 : 0, NSMakeRange(0, 12), nil, @[], NO, NO, nil);
                id item = [message performSelector:@selector(_imMessageItem)];
                id parts = [item performSelector:NSSelectorFromString(@"_newChatItems")];
                NSMutableArray *classes = [NSMutableArray array];
                if ([parts isKindOfClass:NSArray.class]) {
                    for (id part in parts) [classes addObject:NSStringFromClass([part class])];
                }
                NSNumber *type = [item valueForKey:@"associatedMessageType"];
                NSString *actualThread = [message valueForKey:@"threadIdentifier"];
                printf("%s %s\n", multipart ? "multipart" : (threaded ? "threaded" : "plain"),
                    [[NSString stringWithFormat:@"item=%@ parts=%@ type=%@ thread=%@",
                        NSStringFromClass([item class]), classes, type, actualThread] UTF8String]);
                BOOL threadMatches = threaded
                    ? [actualThread isEqual:thread] : !actualThread.length;
                NSUInteger textParts = 0;
                for (NSString *name in classes) {
                    if ([name isEqual:@"IMTextMessagePartChatItem"]) textParts++;
                }
                if (!message || !type || type.longLongValue != 0 || !threadMatches ||
                    textParts < (multipart ? 2 : 1)) {
                    failures++;
                }
            } @catch (NSException *e) {
                fprintf(stderr, "Probe exception: %s %s\n", e.name.UTF8String, e.reason.UTF8String);
                return 3;
            }
        }
        return failures ? 1 : 0;
    }
}
