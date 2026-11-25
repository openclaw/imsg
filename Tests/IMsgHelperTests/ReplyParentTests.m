#import <Foundation/Foundation.h>
#import <dlfcn.h>

static NSUInteger threadCalls;
static BOOL threadRaises;
static NSString *fixtureThreadIdentifier(id part);
static void *fixtureSymbol(void *handle, const char *name) {
    return strcmp(name, "IMCreateThreadIdentifierForMessagePartChatItem") == 0
        ? (void *)fixtureThreadIdentifier : NULL;
}
static Class replyTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMMessage": @"ReplyMessage", @"IMChatRegistry": @"ReplyRegistry",
        @"IMChatHistoryController": @"ReplyHistory", @"IMMessagePartChatItem": @"ReplyPart"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString replyTestClass
#define dlsym fixtureSymbol
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef dlsym
#undef NSClassFromString

static NSUInteger failures;
static NSArray *parentChatItems;
static NSString *existingThread;
static BOOL registryRaises;
static NSUInteger registryRaiseCount;
static id dispatched;

@interface ReplyPart : NSObject
@property NSString *guid;
@end
@implementation ReplyPart
@end

// Stand-ins for the non-part items Messages renders for a retracted parent
// and for an associated message such as a poll vote.
@interface ReplyRetraction : NSObject
@property NSString *guid;
@end
@implementation ReplyRetraction
@end

@interface ReplyAssociated : NSObject
@property NSString *guid;
@end
@implementation ReplyAssociated
@end

static NSString *fixtureThreadIdentifier(id part) {
    threadCalls++;
    if (![part isKindOfClass:[ReplyPart class]] || threadRaises) {
        [NSException raise:NSInvalidArgumentException
                    format:@"-[%@ index]: unrecognized selector", [part class]];
    }
    return [NSString stringWithFormat:@"r:0:0:6:%@", [(ReplyPart *)part guid]];
}

@interface ReplyItem : NSObject
@end
@implementation ReplyItem
- (NSArray *)_newChatItems { return parentChatItems; }
@end

@interface ReplyParent : NSObject
@end
@implementation ReplyParent
- (id)_imMessageItem { return [ReplyItem new]; }
- (NSString *)threadIdentifier { return existingThread; }
- (NSString *)guid { return @"parent-guid"; }
@end

@interface ReplyHistory : NSObject
@end
@implementation ReplyHistory
+ (id)sharedInstance { return [self new]; }
- (void)loadMessageWithGUID:(NSString *)guid completionBlock:(void (^)(id))completion {
    completion([ReplyParent new]);
}
@end

@interface ReplyMessage : NSObject
@property NSString *threadIdentifier;
@property id threadOriginator;
@end
@implementation ReplyMessage
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

@interface ReplyChat : NSObject
@end
@implementation ReplyChat
- (NSString *)guid { return @"iMessage;+;reply-test"; }
- (void)sendMessage:(id)message { dispatched = message; }
@end

@interface ReplyRegistry : NSObject
@end
@implementation ReplyRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    if (registryRaises) {
        registryRaiseCount++;
        [NSException raise:NSInvalidArgumentException format:@"fixture registry failure"];
    }
    return [ReplyChat new];
}
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

static ReplyPart *part(NSString *guid) {
    ReplyPart *item = [ReplyPart new];
    item.guid = guid;
    return item;
}

static NSDictionary *sendReplyV2(NSString *requestId) {
    dispatched = nil;
    threadCalls = 0;
    return processV2Envelope(@{
        @"id": requestId, @"action": @"send-message",
        @"params": @{
            @"chatGuid": @"iMessage;+;reply-test", @"message": @"reply",
            @"selectedMessageGuid": @"parent-guid"
        }
    });
}

static void checkRefused(NSDictionary *response, NSString *label) {
    check(![response[@"success"] boolValue] && dispatched == nil,
          [label stringByAppendingString:@": nothing is dispatched"]);
    check([response[@"delivery_disposition"] isEqual:@"not_started"],
          [label stringByAppendingString:@": the refusal is retry-safe"]);
    check([response[@"error"] containsString:@"Could not resolve reply thread"],
          [label stringByAppendingString:@": the refusal names the reply thread"]);
}

static void writeRequest(NSString *uuid, NSDictionary *envelope) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    [body writeToFile:[kRpcInDir stringByAppendingPathComponent:
        [uuid stringByAppendingPathExtension:@"json"]] atomically:YES];
}

static NSDictionary *readResponse(NSString *uuid) {
    NSData *body = [NSData dataWithContentsOfFile:[kRpcOutDir stringByAppendingPathComponent:
        [uuid stringByAppendingPathExtension:@"json"]]];
    return body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
}

int main(void) {
    @autoreleasepool {
        parentChatItems = @[part(@"parent-guid")];
        NSDictionary *ordinary = sendReplyV2(@"ordinary");
        check([ordinary[@"success"] boolValue], @"An ordinary reply still sends");
        check([((ReplyMessage *)dispatched).threadIdentifier isEqual:@"r:0:0:6:parent-guid"],
              @"An ordinary reply keeps its native thread identifier");

        parentChatItems = @[[ReplyAssociated new], part(@"other-part")];
        NSDictionary *mixed = sendReplyV2(@"mixed");
        check([mixed[@"success"] boolValue]
                  && [((ReplyMessage *)dispatched).threadIdentifier isEqual:@"r:0:0:6:other-part"],
              @"A leading non-part item is skipped in favor of the message part");

        existingThread = @"existing-thread";
        parentChatItems = @[[ReplyAssociated new]];
        NSDictionary *existing = sendReplyV2(@"existing");
        check([existing[@"success"] boolValue] && threadCalls == 0,
              @"An existing thread is reused without deriving a new one");
        check([((ReplyMessage *)dispatched).threadIdentifier isEqual:existingThread],
              @"An existing thread identity is preserved");
        existingThread = nil;

        ReplyRetraction *retraction = [ReplyRetraction new];
        retraction.guid = @"parent-guid";
        parentChatItems = @[retraction];
        checkRefused(sendReplyV2(@"retracted"), @"Reply to a retracted parent");
        check(threadCalls == 0, @"A retraction item never reaches IMCore");

        ReplyAssociated *vote = [ReplyAssociated new];
        vote.guid = @"parent-guid";
        parentChatItems = @[vote];
        checkRefused(sendReplyV2(@"poll-vote"), @"Reply to a poll vote");
        check(threadCalls == 0, @"An associated item never reaches IMCore");

        parentChatItems = @[part(@"parent-guid")];
        threadRaises = YES;
        checkRefused(sendReplyV2(@"raising"), @"Reply whose thread derivation raises");
        threadRaises = NO;

        registryRaises = YES;
        NSDictionary *raised = sendReplyV2(@"handler-raises");
        registryRaises = NO;
        check(![raised[@"success"] boolValue]
                  && [raised[@"delivery_disposition"] isEqual:@"may_have_completed"],
              @"A raising handler returns an uncertain v2 error instead of unwinding");

        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        kRpcDir = [home stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kDebugLogFile = [home stringByAppendingPathComponent:@".imsg-bridge.log"];
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:kRpcInDir withIntermediateDirectories:YES attributes:nil error:nil];
        [files createDirectoryAtPath:kRpcOutDir withIntermediateDirectories:YES attributes:nil error:nil];

        registryRaises = YES;
        registryRaiseCount = 0;
        writeRequest(@"queued-raise", @{
            @"v": @2, @"id": @"queued-raise", @"action": @"send-message",
            @"params": @{@"chatGuid": @"iMessage;+;reply-test", @"message": @"reply"}
        });
        writeRequest(@"queued-ping", @{@"v": @2, @"id": @"queued-ping", @"action": @"ping"});
        scanV2Inbox();
        scanV2Inbox();
        registryRaises = NO;

        NSDictionary *raisedReply = readResponse(@"queued-raise");
        check([raisedReply[@"delivery_disposition"] isEqual:@"may_have_completed"],
              @"A raising queued request still gets an uncertain response");
        check([readResponse(@"queued-ping")[@"success"] boolValue],
              @"The next queued request is still served");
        check(registryRaiseCount == 1, @"A raising request is never replayed");
        NSArray *remaining = [files contentsOfDirectoryAtPath:kRpcInDir error:nil];
        check(remaining.count == 0, @"No request or claim is left in the inbox");
        [files removeItemAtPath:home error:nil];

        fprintf(stdout, "Unsafe reply parents: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
