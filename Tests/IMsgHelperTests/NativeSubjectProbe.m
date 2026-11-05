// Constructs synthetic messages using IMCore. Never resolves a chat or sends.
#import "../../Sources/IMsgHelper/IMsgInjected.m"

static NSString *subjectProbeString(id value) {
    if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW)) {
            fprintf(stderr, "Cannot load IMCore: %s\n", dlerror());
            return 2;
        }
        Class itemClass = NSClassFromString(@"IMMessageItem");
        NSMutableArray *results = [NSMutableArray array];
        NSUInteger failures = 0;
        for (NSNumber *scenario in @[@0, @1, @2]) {
            @try {
                BOOL hasSubject = scenario.integerValue > 0;
                BOOL threaded = scenario.integerValue == 2;
                NSString *bodyText = @"Synthetic subject probe body";
                NSString *subjectText = hasSubject ? @"Ämnesrad åäö ✅" : nil;
                NSString *thread = threaded
                    ? @"0:0:12:00000000-0000-0000-0000-000000000000" : nil;
                id message = buildIMMessage(buildPlainAttributed(bodyText, 0),
                    hasSubject ? buildPlainAttributed(subjectText, 0) : nil,
                    nil, thread, nil, nil, 0, NSMakeRange(0, 0), nil, @[], NO, NO, nil);
                id item = [message performSelector:@selector(_imMessageItem)];
                // IMMessage.subject is a handle; messageSubject is the subject line.
                NSString *messageSubject = subjectProbeString([message valueForKey:@"messageSubject"]);
                NSString *itemSubject = subjectProbeString([item valueForKey:@"subject"]);
                NSString *actualBody = subjectProbeString([message valueForKey:@"text"]);
                NSString *actualThread = [message valueForKey:@"threadIdentifier"];
                BOOL subjectOK = hasSubject
                    ? [messageSubject isEqual:subjectText] && [itemSubject isEqual:subjectText]
                    : !messageSubject.length && !itemSubject.length;
                BOOL threadOK = threaded ? [actualThread isEqual:thread] : !actualThread.length;
                BOOL passed = message && item && subjectOK && threadOK && [actualBody isEqual:bodyText];
                if (!passed) failures++;
                [results addObject:@{
                    @"scenario": threaded ? @"subject_threaded" : (hasSubject ? @"subject_plain" : @"no_subject"),
                    @"passed": @(passed), @"message_subject": messageSubject ?: [NSNull null],
                    @"item_subject": itemSubject ?: [NSNull null],
                    @"body_matches": @([actualBody isEqual:bodyText]), @"thread_matches": @(threadOK),
                    @"item_has_setSubject": @([itemClass instancesRespondToSelector:@selector(setSubject:)]),
                    @"item_has_setMessageSubject": @([itemClass instancesRespondToSelector:@selector(setMessageSubject:)])
                }];
            } @catch (NSException *e) {
                fprintf(stderr, "Probe exception: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
                return 3;
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return failures ? 1 : 0;
    }
}
