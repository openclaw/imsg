#import <Foundation/Foundation.h>

static Class richLinkRefusalClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMMessage": @"RichLinkRefusalMessage",
        @"IMChatRegistry": @"RichLinkRefusalRegistry"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString richLinkRefusalClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;

static void checkNotStarted(NSDictionary *response, NSString *error, NSString *message) {
    NSString *actualError = response[@"error"] ?: @"<missing>";
    NSString *disposition = response[@"delivery_disposition"] ?: @"<missing>";
    BOOL ok = [response[@"success"] isEqual:@NO]
        && [actualError isEqualToString:error]
        && [disposition isEqualToString:@"not_started"];
    if (ok) {
        printf("OK: %s error=%s delivery_disposition=%s\n",
               message.UTF8String, actualError.UTF8String, disposition.UTF8String);
        return;
    }
    fprintf(stderr, "FAIL: %s (success=%s error=%s disposition=%s)\n",
            message.UTF8String,
            response[@"success"] ? [response[@"success"] description].UTF8String : "(nil)",
            actualError.UTF8String,
            disposition.UTF8String);
    failures++;
}

// Caller-owned GUIDs need a message initializer that can carry the GUID.
// The refusal itself returns before any message is built.
@interface RichLinkRefusalMessage : NSObject
@end
@implementation RichLinkRefusalMessage
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)text
     messageSubject:(id)messageSubject fileTransferGUIDs:(NSArray *)transfers
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subject balloonBundleID:(id)balloon payloadData:(id)data
 expressiveSendStyleID:(id)effect {
    return [super init];
}
@end

@interface RichLinkRefusalAccount : NSObject
@property NSString *serviceName;
@end
@implementation RichLinkRefusalAccount
@end

@interface RichLinkRefusalChat : NSObject
@property NSString *guid;
@property RichLinkRefusalAccount *account;
@end
@implementation RichLinkRefusalChat
@end

@interface RichLinkRefusalRegistry : NSObject
@end
@implementation RichLinkRefusalRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    if (![guid isEqualToString:@"iMessage;-;+15550001111"]) return nil;
    RichLinkRefusalChat *chat = [RichLinkRefusalChat new];
    chat.guid = guid;
    RichLinkRefusalAccount *account = [RichLinkRefusalAccount new];
    account.serviceName = @"SMS";
    chat.account = account;
    return chat;
}
@end

static NSDictionary *richLinkParams(NSDictionary *overrides) {
    NSMutableDictionary *params = [@{
        @"chatGuid": @"iMessage;-;+15550001111",
        @"message": @"https://example.com/preview",
        @"richLinkPreview": @{@"originalURL": @"https://example.com/preview"},
        @"ddScan": @YES
    } mutableCopy];
    [params addEntriesFromDictionary:overrides];
    return params;
}

int main(void) {
    @autoreleasepool {
        // These three refusals happen before a rich link is built or sent.
        // The response has to say nothing started, or a retry looks unsafe.
        checkNotStarted(
            handleSendMessage(1, richLinkParams(@{
                @"clientMessageGuid": @"A093F4F2-D812-4CA2-A2A3-575C114512BA"
            })),
            @"Caller-owned message GUIDs support text messages only",
            @"A rich link with a caller GUID was not started");
        checkNotStarted(
            handleSendMessage(2, richLinkParams(@{@"effectId": @"com.apple.messages.effect.Echo"})),
            @"Rich links do not support send modifiers",
            @"A rich link with a send modifier was not started");
        checkNotStarted(
            handleSendMessage(3, richLinkParams(@{})),
            @"Rich links require an iMessage chat",
            @"A rich link on a live SMS chat was not started");

        printf("Bridge rich-link refusal tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
