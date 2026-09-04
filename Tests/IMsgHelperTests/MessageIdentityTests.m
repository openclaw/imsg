#import <Foundation/Foundation.h>
static Class identityTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMMessage": @"IdentityMessage", @"IMChatRegistry": @"IdentityRegistry",
        @"IMChatHistoryController": @"IdentityHistory", @"IMMessagePartChatItem": @"IdentityPart"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString identityTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static id dispatchedMessage;
static NSString *loadedGUID;
static NSUInteger failures;
static BOOL omitGUID;

@interface IdentityMessage : NSObject
@property NSString *guid;
@property NSAttributedString *text;
@property NSString *associatedGUID;
@property NSRange associatedRange;
@end
@implementation IdentityMessage
- (id)initWithText:(NSAttributedString *)text flags:(unsigned long long)flags {
    if ((self = [super init])) { self.guid = omitGUID ? nil : @"new-message-guid"; self.text = text; }
    return self;
}
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)text
     messageSubject:(id)messageSubject fileTransferGUIDs:(NSArray *)transfers
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subject associatedMessageGUID:(NSString *)associatedGUID
 associatedMessageType:(long long)type associatedMessageRange:(NSRange)range
 messageSummaryInfo:(NSDictionary *)summary {
    self = [self initWithText:text flags:flags];
    self.associatedGUID = associatedGUID;
    self.associatedRange = range;
    return self;
}
@end

@interface IdentityPart : NSObject
@property NSInteger index;
@property NSRange messagePartRange;
@property (weak) id messageItem;
@end
@implementation IdentityPart
- (NSString *)text { return self.index == 0 ? @"first" : @"second"; }
@end

@interface IdentityBacking : NSObject
@property NSArray *parts;
@end
@implementation IdentityBacking
- (NSArray *)_newChatItems { return self.parts; }
@end

@interface IdentityParent : NSObject
@property IdentityBacking *backing;
@end
@implementation IdentityParent
- (id)_imMessageItem { return self.backing; }
- (NSAttributedString *)text { return [[NSAttributedString alloc] initWithString:@"first second"]; }
@end
static IdentityParent *parent;

@interface IdentityHistory : NSObject
@end
@implementation IdentityHistory
+ (id)sharedInstance { return [self new]; }
- (void)loadMessageWithGUID:(NSString *)guid completionBlock:(void (^)(id))completion {
    loadedGUID = guid;
    completion([guid isEqual:@"parent-guid"] ? parent : nil);
}
@end

@interface IdentityChat : NSObject
@end
@implementation IdentityChat
- (NSString *)guid { return @"iMessage;+;chat-test"; }
- (id)lastSentMessage {
    IdentityMessage *old = [IdentityMessage new];
    old.guid = @"old-message-guid";
    return old;
}
- (void)sendMessage:(id)message { dispatchedMessage = message; }
- (void)sendMessage:(id)message reason:(NSInteger)reason { [self sendMessage:message]; }
@end

@interface IdentityRegistry : NSObject
@end
@implementation IdentityRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid { return [IdentityChat new]; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

int main(void) {
    @autoreleasepool {
        parent = [IdentityParent new];
        parent.backing = [IdentityBacking new];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSInteger index = 0; index < 2; index++) {
            IdentityPart *part = [IdentityPart new];
            part.index = index;
            part.messagePartRange = NSMakeRange(index * 6, 5);
            part.messageItem = parent.backing;
            [parts addObject:part];
        }
        parent.backing.parts = parts;

        for (NSNumber *deferred in @[@NO, @YES]) {
            gHasSendMessageReason = deferred.boolValue;
            dispatchedMessage = nil;
            NSDictionary *result = handleSendMessage(1, @{
                @"chatGuid": @"iMessage;+;chat-test", @"message": @"hello", @"ddScan": deferred
            });
            check([result[@"success"] boolValue], @"Text send succeeds through the synthetic chat");
            check([result[@"messageGuid"] isEqual:@"new-message-guid"],
                  @"Acknowledgment identifies the constructed message, never stale chat history");
            if (deferred.boolValue) {
                check(dispatchedMessage == nil, @"Deferred acknowledgment precedes dispatch");
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            }
            check([dispatchedMessage isKindOfClass:IdentityMessage.class], @"Only the fake transport receives the message");
        }
        for (NSString *reference in @[@"parent-guid", @"p:1/parent-guid"]) {
            loadedGUID = nil;
            dispatchedMessage = nil;
            NSDictionary *result = handleSendReaction(2, @{
                @"chatGuid": @"iMessage;+;chat-test", @"selectedMessageGuid": reference,
                @"reactionType": @"like", @"partIndex": [reference hasPrefix:@"p:"] ? @0 : @1
            });
            IdentityMessage *message = dispatchedMessage;
            check([result[@"success"] boolValue], @"Multipart reaction succeeds");
            check([message.associatedGUID isEqual:@"p:1/parent-guid"], @"Reaction retains the selected part reference");
            check(NSEqualRanges(message.associatedRange, NSMakeRange(6, 5)), @"Reaction range belongs to part one");
            check([loadedGUID isEqual:@"parent-guid"], @"History lookup uses the bare message GUID");
            check([result[@"messageGuid"] isEqual:message.guid], @"Reaction result identifies the newly dispatched message");
        }
        dispatchedMessage = nil;
        NSDictionary *missing = handleSendReaction(3, @{
            @"chatGuid": @"iMessage;+;chat-test", @"selectedMessageGuid": @"parent-guid",
            @"reactionType": @"remove-like", @"partIndex": @3
        });
        check(![missing[@"success"] boolValue] && dispatchedMessage == nil,
              @"An absent selected part must fail before sending");
        omitGUID = YES;
        NSDictionary *withoutGUID = handleSendMessage(4, @{
            @"chatGuid": @"iMessage;+;chat-test", @"message": @"hello"
        });
        check([withoutGUID[@"messageGuid"] isEqual:@""], @"An unavailable new GUID must never fall back to old history");
        fprintf(stdout, "Bridge message identity tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
