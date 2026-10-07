#import <Foundation/Foundation.h>
static Class identityTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMMessage": @"IdentityMessage", @"IMChatRegistry": @"IdentityRegistry",
        @"IMChatHistoryController": @"IdentityHistory", @"IMMessagePartChatItem": @"IdentityPart",
        @"IMEmojiTapback": @"TestEmojiTapback", @"IMTapbackSender": @"TestTapbackSender"
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
static BOOL identifierLookupAvailable;

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
            subject:(id)subject balloonBundleID:(id)balloon payloadData:(id)data
 expressiveSendStyleID:(id)effect {
    self = [self initWithText:text flags:flags];
    if (guid.length) self.guid = guid;
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

// Emoji-tapback fixtures. The emoji path builds an IMEmojiTapback and an
// IMTapbackSender through NSInvocation. The sender is the invocation's TARGET,
// which NSInvocation retains only in -retainArguments, so the instance handed
// to -setTarget: must outlive that call. These stubs let the builder run
// without Messages.app and observe whether the target survived.
static BOOL emojiTapbackInitCalled;
static BOOL senderInitCalled;
static BOOL senderSendCalled;
static NSInteger senderDeallocCount;
static NSInteger senderDeallocCountAtSend = -1;

@interface TestEmojiTapback : NSObject
@end
@implementation TestEmojiTapback
- (id)initWithEmoji:(id)emoji isRemoved:(BOOL)removed {
    if ((self = [super init])) { emojiTapbackInitCalled = YES; }
    return self;
}
@end

@interface TestTapbackSender : NSObject
@end
@implementation TestTapbackSender
- (id)initWithTapback:(id)tapback chat:(id)chat messagePartChatItem:(id)item {
    if ((self = [super init])) { senderInitCalled = YES; }
    return self;
}
- (id)initWithTapback:(id)tapback chat:(id)chat messageGUID:(NSString *)guid
     messagePartRange:(NSRange)range messageSummaryInfo:(NSDictionary *)info
     threadIdentifier:(NSString *)threadIdentifier {
    if ((self = [super init])) { senderInitCalled = YES; }
    return self;
}
- (void)send { senderSendCalled = YES; senderDeallocCountAtSend = senderDeallocCount; }
- (void)dealloc { senderDeallocCount += 1; }
@end

@interface IdentityRegistry : NSObject
@end
@implementation IdentityRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    return [guid isEqual:@"iMessage;+;chat-test"] || [guid isEqual:@"any;+;group-test"]
        ? [IdentityChat new] : nil;
}
- (id)existingChatWithChatIdentifier:(NSString *)identifier {
    return identifierLookupAvailable && [identifier isEqual:@"identifier-only"]
        ? [IdentityChat new] : nil;
}
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
        for (NSString *target in @[@"group-test", @"identifier-only"]) {
            identifierLookupAvailable = YES;
            dispatchedMessage = nil;
            NSDictionary *group = handleSendMessage(5, @{
                @"chatGuid": target, @"message": @"group fixture"
            });
            check([group[@"success"] boolValue] && dispatchedMessage != nil,
                  @"Bare group identifiers resolve without a database or a visible conversation");
            check([group[@"chatGuid"] isEqual:@"iMessage;+;chat-test"],
                  @"Send acknowledgment returns the resolved canonical chat GUID");
        }
        for (NSString *target in @[@"missing-group", @"SMS;+;group-test", @"not-group-test"]) {
            dispatchedMessage = nil;
            NSDictionary *missingChat = handleSendMessage(6, @{
                @"chatGuid": target, @"message": @"must not send"
            });
            check(![missingChat[@"success"] boolValue] && dispatchedMessage == nil,
                  @"Absent or explicitly different chats never dispatch");
            check([missingChat[@"delivery_disposition"] isEqual:@"not_started"],
                  @"Missing chat is a proven pre-dispatch rejection");
        }
        NSString *attempt = @"a093f4f2-d812-4ca2-a2a3-575c114512ba";
        dispatchedMessage = nil;
        NSDictionary *tracked = processV2Envelope(@{
            @"id": @"tracked-fixture", @"action": @"send-message",
            @"params": @{@"chatGuid": @"group-test", @"message": @"tracked",
                         @"clientMessageGuid": attempt}
        });
        check([tracked[@"data"][@"messageGuid"] isEqual:attempt] && dispatchedMessage != nil,
              @"Tracked group send retains the caller GUID through the v2 envelope");
        dispatchedMessage = nil;
        NSDictionary *rejected = processV2Envelope(@{
            @"id": @"missing-fixture", @"action": @"send-message",
            @"params": @{@"chatGuid": @"missing-group", @"message": @"tracked",
                         @"clientMessageGuid": @"b093f4f2-d812-4ca2-a2a3-575c114512ba"}
        });
        check([rejected[@"delivery_disposition"] isEqual:@"not_started"] && dispatchedMessage == nil,
              @"V2 preserves a tracked send's proven pre-dispatch rejection");
        omitGUID = YES;
        NSDictionary *withoutGUID = handleSendMessage(4, @{
            @"chatGuid": @"iMessage;+;chat-test", @"message": @"hello"
        });
        check([withoutGUID[@"messageGuid"] isEqual:@""], @"An unavailable new GUID must never fall back to old history");
        // Emoji tapbacks: the sender is the NSInvocation target and must survive
        // -retainArguments. On the unfixed builder the target is an ARC temporary
        // released at the end of the -setTarget: statement, so -retainArguments
        // retains a freed object (crash) or the sender is built on freed memory
        // (dealloc before send); either way the assertions below fail.
        emojiTapbackInitCalled = NO;
        senderInitCalled = NO;
        senderSendCalled = NO;
        senderDeallocCount = 0;
        senderDeallocCountAtSend = -1;
        NSDictionary *emojiResult = handleSendReaction(7, @{
            @"chatGuid": @"iMessage;+;chat-test",
            @"selectedMessageGuid": @"parent-guid",
            @"emoji": @"🎉",
            @"partIndex": @0
        });
        check([emojiResult[@"success"] boolValue], @"An emoji tapback succeeds through the emoji path");
        check(emojiTapbackInitCalled, @"The emoji path constructs IMEmojiTapback");
        check(senderInitCalled, @"The emoji path constructs IMTapbackSender");
        check(senderSendCalled, @"The emoji path dispatches the tapback sender");
        check(senderDeallocCountAtSend == 0,
              @"The sender invocation target is alive when the tapback is sent");
        fprintf(stdout, "Bridge message identity tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
