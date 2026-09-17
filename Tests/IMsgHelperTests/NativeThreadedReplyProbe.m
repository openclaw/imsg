// Optional macOS probe using real IMCore classes. Run manually; never sends,
// resolves a conversation, or opens the Messages database. Example build:
// clang -fobjc-arc -Wno-arc-performSelector-leaks -framework Foundation \
//   -framework AppKit -framework ImageIO -framework LinkPresentation \
//   Tests/IMsgHelperTests/NativeThreadedReplyProbe.m -o /tmp/imsg-reply-probe
// /tmp/imsg-reply-probe
#import "../../Sources/IMsgHelper/IMsgInjected.m"

int main(void) {
    @autoreleasepool {
        void *core = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW);
        if (!core) { fprintf(stderr, "Cannot load IMCore: %s\n", dlerror()); return 2; }
        NSUInteger failures = 0;
        for (NSNumber *threaded in @[@NO, @YES]) {
            @try {
                NSString *thread = threaded.boolValue
                    ? @"0:0:12:00000000-0000-0000-0000-000000000000" : nil;
                id message = buildIMMessage(buildPlainAttributed(@"Local rendering probe", 0),
                    nil, nil, thread, nil,
                    threaded.boolValue ? @"00000000-0000-0000-0000-000000000000" : nil,
                    threaded.boolValue ? 100 : 0, NSMakeRange(0, 12), nil, @[], NO, NO, nil);
                id item = [message performSelector:@selector(_imMessageItem)];
                id parts = [item performSelector:NSSelectorFromString(@"_newChatItems")];
                NSMutableArray *classes = [NSMutableArray array];
                if ([parts isKindOfClass:NSArray.class]) {
                    for (id part in parts) [classes addObject:NSStringFromClass([part class])];
                }
                NSNumber *type = [item valueForKey:@"associatedMessageType"];
                NSString *actualThread = [message valueForKey:@"threadIdentifier"];
                printf("%s %s\n", threaded.boolValue ? "threaded" : "plain",
                    [[NSString stringWithFormat:@"item=%@ parts=%@ type=%@ thread=%@",
                        NSStringFromClass([item class]), classes, type, actualThread] UTF8String]);
                BOOL threadMatches = threaded.boolValue
                    ? [actualThread isEqual:thread] : !actualThread.length;
                if (!message || !type || type.longLongValue != 0 || !threadMatches ||
                    ![classes containsObject:@"IMTextMessagePartChatItem"]) {
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
