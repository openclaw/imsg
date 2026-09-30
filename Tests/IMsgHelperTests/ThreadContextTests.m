#import <Foundation/Foundation.h>
#import <dlfcn.h>

static BOOL invalidThreadPart;
static NSString *fixtureThreadIdentifier(id part) {
    if (![part isKindOfClass:[NSString class]]) invalidThreadPart = YES;
    return [part isEqual:@"parent-part"] ? @"r:0:0:6:parent-guid" : nil;
}
static void *fixtureSymbol(void *handle, const char *name) {
    return strcmp(name, "IMCreateThreadIdentifierForMessagePartChatItem") == 0
        ? (void *)fixtureThreadIdentifier : NULL;
}
static Class contextTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMMessage": @"ContextMessage", @"IMChatRegistry": @"ContextRegistry",
        @"IMChatHistoryController": @"ContextHistory", @"IMMutableChatContext": @"ContextProvider"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString contextTestClass
#define dlsym fixtureSymbol
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef dlsym
#undef NSClassFromString

static NSUInteger failures;
static BOOL hasUnscopedSelector;
static BOOL hasBackingSelector = YES;
static BOOL hasContext;
static BOOL contextRequested;
static BOOL itemThrows;
static NSString *existingThread;
static id dispatched;

@interface ContextItem : NSObject
@end
@implementation ContextItem
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(_newChatItems)) return hasUnscopedSelector;
    return [super respondsToSelector:selector];
}
- (NSArray *)_newChatItems { return @[]; }
- (NSArray *)_newChatItemsWithChatContext:(id)context {
    if (itemThrows) [NSException raise:@"FixtureFailure" format:@"unavailable"];
    return context ? @[@"parent-part"] : nil;
}
@end

@interface ContextParent : NSObject
@end
@implementation ContextParent
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(_imMessageItem)) return hasBackingSelector;
    return [super respondsToSelector:selector];
}
- (id)_imMessageItem { return [ContextItem new]; }
- (NSString *)threadIdentifier { return existingThread; }
- (NSString *)guid { return @"parent-guid"; }
@end

@interface ContextHistory : NSObject
@end
@implementation ContextHistory
+ (id)sharedInstance { return [self new]; }
- (void)loadMessageWithGUID:(NSString *)guid completionBlock:(void (^)(id))completion {
    completion([ContextParent new]);
}
@end

@interface ContextProvider : NSObject
@end
@implementation ContextProvider
+ (id)chatContextForPinnedChat:(id)chat {
    contextRequested = YES;
    return hasContext && chat ? [NSObject new] : nil;
}
@end

@interface ContextMessage : NSObject
@property NSString *threadIdentifier;
@property id threadOriginator;
@end
@implementation ContextMessage
- (id)initWithText:(NSAttributedString *)text flags:(unsigned long long)flags {
    return [super init];
}
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)text
     messageSubject:(id)messageSubject fileTransferGUIDs:(NSArray *)transfers
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subject associatedMessageGUID:(NSString *)associatedGUID
 associatedMessageType:(long long)type associatedMessageRange:(NSRange)range
 messageSummaryInfo:(NSDictionary *)summary {
    return [self initWithText:text flags:flags];
}
- (NSString *)guid { return @"reply-guid"; }
@end

@interface ContextChat : NSObject
@end
@implementation ContextChat
- (NSString *)guid { return @"iMessage;+;context-test"; }
- (void)sendMessage:(id)message { dispatched = message; }
@end

@interface ContextRegistry : NSObject
@end
@implementation ContextRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid { return [ContextChat new]; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}
static NSDictionary *sendReply(void) {
    dispatched = nil;
    contextRequested = NO;
    return handleSendMessage(1, @{
        @"chatGuid": @"iMessage;+;context-test", @"message": @"reply",
        @"selectedMessageGuid": @"parent-guid"
    });
}
int main(void) {
    @autoreleasepool {
        for (NSNumber *selector in @[@NO, @YES]) {
            hasUnscopedSelector = selector.boolValue;
            hasContext = YES;
            existingThread = nil;
            NSDictionary *result = sendReply();
            check([result[@"success"] boolValue] && contextRequested,
                  @"Unloaded parents materialize chat items with the target chat context");
            check([((ContextMessage *)dispatched).threadIdentifier isEqual:@"r:0:0:6:parent-guid"],
                  @"An unloaded parent's reply retains its native thread identifier");
        }
        existingThread = @"existing-thread";
        hasContext = NO;
        for (NSNumber *backing in @[@NO, @YES]) {
            hasBackingSelector = backing.boolValue;
            NSDictionary *existing = sendReply();
            check([existing[@"success"] boolValue] && !contextRequested,
                  @"Existing threads do not require a backing-item selector or rendered items");
            check([((ContextMessage *)dispatched).threadIdentifier isEqual:existingThread],
                  @"Existing thread identity is preserved");
        }
        existingThread = nil;
        hasUnscopedSelector = NO;
        for (NSNumber *throws in @[@NO, @YES]) {
            itemThrows = throws.boolValue;
            hasContext = itemThrows;
            NSDictionary *unavailable = sendReply();
            check(![unavailable[@"success"] boolValue] && dispatched == nil,
                  @"An unresolved explicit reply never dispatches as plain text");
            check([unavailable[@"delivery_disposition"] isEqual:@"not_started"],
                  @"An unresolved reply reports a safe pre-dispatch rejection");
        }
        check(!invalidThreadPart, @"Thread derivation never receives a raw backing message item");
        fprintf(stdout, "Unloaded reply context: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
