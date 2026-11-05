// Drive the typing observer with the notification IMCore posts and check what
// lands in the event log.
#import <Foundation/Foundation.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

static NSUInteger failures;
static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

@interface IMTypingChatItem : NSObject
@end
@implementation IMTypingChatItem
@end

@interface IMGroupTypingChatItem : IMTypingChatItem
@end
@implementation IMGroupTypingChatItem
@end

@interface TypingTestTextItem : NSObject
@end
@implementation TypingTestTextItem
@end

@interface TypingTestBannerItem : NSObject
@end
@implementation TypingTestBannerItem
@end

@interface TypingTestChat : NSObject
@property id guid;
@end
@implementation TypingTestChat
@end

@interface TypingThrowingChat : NSObject
@end
@implementation TypingThrowingChat
- (id)guid {
    [NSException raise:NSInvalidArgumentException format:@"Unavailable selector"];
    return nil;
}
@end

static void postItems(id chat, id oldItems, id newItems) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"__kIMChatItemsOldItems"] = oldItems;
    userInfo[@"__kIMChatItemsNewItems"] = newItems;
    [NSNotificationCenter.defaultCenter postNotificationName:@"__kIMChatItemsDidChangeNotification"
                                                      object:chat
                                                    userInfo:userInfo];
}

static TypingTestChat *chatWithGuid(id guid) {
    TypingTestChat *chat = [TypingTestChat new];
    chat.guid = guid;
    return chat;
}

/// Each line as "event chatGuid", in order.
static NSArray<NSString *> *loggedEvents(void) {
    NSString *log = [NSString stringWithContentsOfFile:kEventsFile
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    NSMutableArray *events = [NSMutableArray array];
    for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        [events addObject:[NSString stringWithFormat:@"%@ %@", event[@"event"], event[@"data"][@"chatGuid"]]];
    }
    return events;
}

int main(void) {
    @autoreleasepool {
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES
                                                attributes:nil error:nil];
        // initFilePaths leaves the paths alone once kCommandFile is set.
        kCommandFile = [home stringByAppendingPathComponent:@".imsg-command.json"];
        kEventsFile = [home stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [home stringByAppendingPathComponent:@".imsg-events.jsonl.1"];

        registerEventObservers();

        id text = [TypingTestTextItem new];
        id typing = [IMTypingChatItem new];
        TypingTestChat *alice = chatWithGuid(@"iMessage;-;+15550000001");
        TypingTestChat *bob = chatWithGuid(@"iMessage;-;+15550000002");

        postItems(alice, @[text], @[text, text]);
        check(loggedEvents().count == 0, @"A change with no typing item emits nothing");

        postItems(alice, @[text], @[text, typing]);
        postItems(alice, @[text, typing], @[text, typing]);
        postItems(bob, @[], @[typing]);
        postItems(alice, @[text, typing], @[text, text]);
        postItems(bob, @[typing], @[text]);
        NSArray *expected = @[
            @"started-typing iMessage;-;+15550000001",
            @"started-typing iMessage;-;+15550000002",
            @"stopped-typing iMessage;-;+15550000001",
            @"stopped-typing iMessage;-;+15550000002",
        ];
        check([loggedEvents() isEqualToArray:expected],
              [NSString stringWithFormat:@"A typing item appearing or leaving emits, got %@",
                                         loggedEvents()]);

        id banner = [TypingTestBannerItem new];
        TypingTestChat *carol = chatWithGuid(@"iMessage;-;+15550000003");
        postItems(carol, @[text, banner], @[text, typing, banner]);
        postItems(carol, @[text, typing, banner], @[text, text, banner]);
        expected = [expected arrayByAddingObjectsFromArray:@[
            @"started-typing iMessage;-;+15550000003",
            @"stopped-typing iMessage;-;+15550000003",
        ]];
        check([loggedEvents() isEqualToArray:expected],
              @"A typing item still counts when a banner item follows it");

        TypingTestChat *group = chatWithGuid(@"iMessage;+;chat000000000000000001");
        postItems(group, @[text], @[text, [IMGroupTypingChatItem new]]);
        postItems(group, @[text, [IMGroupTypingChatItem new]], @[text, text]);
        expected = [expected arrayByAddingObjectsFromArray:@[
            @"started-typing iMessage;+;chat000000000000000001",
            @"stopped-typing iMessage;+;chat000000000000000001",
        ]];
        check([loggedEvents() isEqualToArray:expected], @"A group typing item counts as typing");

        NSUInteger before = loggedEvents().count;
        postItems(chatWithGuid(nil), @[text], @[text, typing]);
        postItems(chatWithGuid(@""), @[text], @[text, typing]);
        postItems(chatWithGuid(@42), @[text], @[text, typing]);
        postItems([NSObject new], @[text], @[text, typing]);
        postItems([TypingThrowingChat new], @[text], @[text, typing]);
        check(loggedEvents().count == before,
              @"A missing, empty, non-string, or throwing chat GUID emits nothing");

        postItems(alice, nil, @[text, typing]);
        postItems(alice, @[text], nil);
        postItems(alice, @{@"items": @[text]}, @[text, typing]);
        postItems(alice, @[text], @{@"items": @[text, typing]});
        check(loggedEvents().count == before, @"A missing or non-array item list emits nothing");

        [NSFileManager.defaultManager removeItemAtPath:home error:nil];
        fprintf(stdout, "Bridge typing event tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
