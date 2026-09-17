#import <Foundation/Foundation.h>

static BOOL itemConstructionAvailable = YES;
static Class testMessageClass(NSString *name) {
    if ([name isEqual:@"IMMessage"]) return NSClassFromString(@"ReplyTestMessage");
    if ([name isEqual:@"IMMessageItem"]) {
        return itemConstructionAvailable ? NSClassFromString(@"ReplyTestItem") : Nil;
    }
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString testMessageClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;
static NSUInteger associatedInitializations;

@interface ReplyTestItem : NSObject
@property NSAttributedString *body;
@property NSData *bodyData;
@property NSString *threadIdentifier;
@property id threadOriginator;
@property NSString *associatedMessageGUID;
@property long long associatedMessageType;
@property NSRange associatedMessageRange;
@property NSDictionary *messageSummaryInfo;
@property NSAttributedString *subject;
@property NSString *expressiveSendStyleID;
@property NSArray *fileTransferGUIDs;
@property unsigned long long flags;
@end
@implementation ReplyTestItem
- (void)setMessageSubject:(NSAttributedString *)subject { self.subject = subject; }
- (id)initWithSender:(id)sender time:(NSDate *)time body:(NSAttributedString *)body
         attributes:(id)attributes fileTransferGUIDs:(NSArray *)files
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
   threadIdentifier:(NSString *)thread {
    if ((self = [super init])) {
        self.body = body; self.fileTransferGUIDs = files;
        self.flags = flags; self.threadIdentifier = thread;
    }
    return self;
}
@end

@interface ReplyTestMessage : NSObject
@property ReplyTestItem *item;
@property NSString *threadIdentifier;
@property id threadOriginator;
@end
@implementation ReplyTestMessage
+ (id)messageFromIMMessageItem:(ReplyTestItem *)item sender:(id)sender subject:(id)subject {
    ReplyTestMessage *message = [self new];
    message.item = item;
    message.threadIdentifier = item.threadIdentifier;
    message.threadOriginator = item.threadOriginator;
    return message;
}
- (id)_imMessageItem { return self.item; }
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)body
     messageSubject:(id)subject fileTransferGUIDs:(NSArray *)files
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subjectString balloonBundleID:(id)balloon payloadData:(id)data
 expressiveSendStyleID:(NSString *)effect {
    if ((self = [super init])) {
        self.item = [ReplyTestItem new];
        self.item.body = body; self.item.subject = subject;
        self.item.fileTransferGUIDs = files; self.item.flags = flags;
        self.item.expressiveSendStyleID = effect;
    }
    return self;
}
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)body
     messageSubject:(id)subject fileTransferGUIDs:(NSArray *)files
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subjectString associatedMessageGUID:(NSString *)associatedGUID
 associatedMessageType:(long long)type associatedMessageRange:(NSRange)range
 messageSummaryInfo:(NSDictionary *)summary {
    self = [self initWithSender:sender time:time text:body messageSubject:subject
             fileTransferGUIDs:files flags:flags error:error guid:guid
                       subject:subjectString balloonBundleID:nil payloadData:nil
         expressiveSendStyleID:nil];
    associatedInitializations++;
    self.item.associatedMessageGUID = associatedGUID;
    self.item.associatedMessageType = type;
    self.item.associatedMessageRange = range;
    self.item.messageSummaryInfo = summary;
    return self;
}
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

int main(void) {
    @autoreleasepool {
        NSAttributedString *body = [[NSAttributedString alloc] initWithString:@"reply test"];
        NSAttributedString *subject = [[NSAttributedString alloc] initWithString:@"subject"];
        NSObject *parent = [NSObject new];
        NSString *thread = @"0:0:12:parent-guid";

        // Native text replies are ordinary visible messages with separate thread metadata.
        for (NSNumber *modern in @[@YES, @NO]) {
            itemConstructionAvailable = modern.boolValue;
            associatedInitializations = 0;
            ReplyTestMessage *reply = buildIMMessage(body, subject, @"effect", thread, parent,
                @"parent-guid", 100, NSMakeRange(0, body.length), nil, @[], NO, NO, nil);
            check(reply != nil, @"A threaded reply can be constructed");
            check(associatedInitializations == 0, @"Native replies do not use the reaction initializer");
            check(reply.item.associatedMessageType == 0 && !reply.item.associatedMessageGUID,
                  @"Native replies have no legacy associated-message classification");
            check([reply.threadIdentifier isEqual:thread], @"The native thread identifier survives construction");
            check([reply.item.body.string isEqual:body.string], @"Reply text survives construction");
            check(reply.item.flags == 0x10000dULL, @"Replies retain normal subject finalization flags");
            check([reply.item.subject.string isEqual:subject.string], @"Reply subject survives construction");
            check([reply.item.expressiveSendStyleID isEqual:@"effect"], @"Reply effect survives construction");
            if (modern.boolValue) {
                check(reply.item.threadOriginator == parent, @"The item retains its thread originator");
                check(reply.item.bodyData.length > 0, @"Modern reply contains a serialized message body");
            }
        }
        itemConstructionAvailable = YES;

        associatedInitializations = 0;
        ReplyTestMessage *attachment = buildIMMessage(body, nil, nil, thread, parent,
            @"parent-guid", 100, NSMakeRange(0, 1), nil, @[@"transfer-guid"], NO, NO, nil);
        check(associatedInitializations == 0 && attachment.item.associatedMessageType == 0,
              @"Attachment replies use the normal attachment constructor");
        check([attachment.threadIdentifier isEqual:thread] &&
              [attachment.item.fileTransferGUIDs isEqual:@[@"transfer-guid"]],
              @"Attachment replies preserve both their thread and transfer");

        // Actual reactions and attached stickers must retain their association semantics.
        for (NSNumber *type in @[@1000, @2000, @2001, @3001]) {
            NSDictionary *summary = @{ @"amc": @1, @"ams": @"parent text" };
            associatedInitializations = 0;
            ReplyTestMessage *reaction = buildIMMessage(body, nil, nil, nil, nil,
                @"p:0/parent-guid", type.longLongValue, NSMakeRange(0, 12), summary, @[], NO, NO, nil);
            check(associatedInitializations == 1, @"Reactions retain the associated-message initializer");
            check(reaction.item.associatedMessageType == type.longLongValue &&
                  [reaction.item.associatedMessageGUID isEqual:@"p:0/parent-guid"],
                  @"Reaction type and target are unchanged");
            check([reaction.item.messageSummaryInfo isEqual:summary], @"Reaction summary is unchanged");
        }

        ReplyTestMessage *legacy = buildIMMessage(body, nil, nil, nil, nil,
            @"parent-guid", 100, NSMakeRange(0, 12), nil, @[], NO, NO, nil);
        check(legacy.item.associatedMessageType == 100, @"Unresolved legacy reply fallback is unchanged");
        ReplyTestMessage *plain = buildIMMessage(body, nil, nil, nil, nil,
            nil, 0, NSMakeRange(0, 0), nil, @[], NO, NO, nil);
        check(plain != nil && !plain.threadIdentifier && plain.item.associatedMessageType == 0,
              @"Plain messages remain unthreaded");
        fprintf(stdout, "Threaded reply construction: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
