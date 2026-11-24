#import <Foundation/Foundation.h>

static Class sendLaterClass(NSString *name) {
    if ([name isEqualToString:@"IMMessage"]) return NSClassFromString(@"SendLaterMessage");
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString sendLaterClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;

static void check(BOOL ok, NSString *message) {
    if (ok) {
        printf("OK: %s\n", message.UTF8String);
    } else {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        failures++;
    }
}

// Records what the scheduled builder hands IMCore's initializer and setters.
@interface SendLaterMessage : NSObject
@property NSDate *time;
@property NSAttributedString *text;
@property unsigned long long scheduleType;
@property unsigned long long scheduleState;
@end
@implementation SendLaterMessage
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)text
     messageSubject:(id)messageSubject fileTransferGUIDs:(NSArray *)transfers
              flags:(unsigned long long)flags error:(id)error guid:(NSString *)guid
            subject:(id)subject balloonBundleID:(id)balloon payloadData:(id)data
 expressiveSendStyleID:(id)effect {
    if ((self = [super init])) {
        _time = time;
        _text = text;
    }
    return self;
}
@end

static void checkRefused(NSDictionary *params, NSString *error, NSString *message) {
    NSDictionary *response = handleSendMessage(1, params);
    check([response[@"success"] isEqual:@NO] &&
          [response[@"error"] isEqualToString:error] &&
          [response[@"delivery_disposition"] isEqualToString:@"not_started"],
          message);
}

int main(void) {
    @autoreleasepool {
        NSString *chat = @"iMessage;-;+15550000000";
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        checkRefused(@{@"chatGuid": chat, @"message": @"late", @"sendAt": @(now - 60)},
                     @"sendAt must be in the future and at most 14 days ahead",
                     @"a delivery time in the past is refused before anything is built");
        checkRefused(@{@"chatGuid": chat, @"message": @"far", @"sendAt": @(now + 15 * 24 * 3600)},
                     @"sendAt must be in the future and at most 14 days ahead",
                     @"a delivery time past the two-week window is refused");
        checkRefused(@{@"chatGuid": chat, @"message": @"boom", @"sendAt": @(now + 600),
                       @"effectId": @"com.apple.MobileSMS.expressivesend.impact"},
                     @"Send Later supports text, formatting and a subject only",
                     @"a bubble effect with Send Later is refused");
        checkRefused(@{@"chatGuid": chat, @"message": @"hi", @"sendAt": @(now + 600),
                       @"selectedMessageGuid": @"PARENT"},
                     @"Send Later supports text, formatting and a subject only",
                     @"a reply with Send Later is refused");
        NSDictionary *badType = handleSendMessage(1, @{@"chatGuid": chat, @"sendAt": @"9am"});
        check([badType[@"error"] isEqualToString:@"Invalid send-message parameter types"],
              @"sendAt must be a number of seconds since 1970");

        NSDate *when = [NSDate dateWithTimeIntervalSince1970:1900000000];
        NSAttributedString *body = buildPlainAttributed(@"see you at nine", 0);
        SendLaterMessage *m = buildScheduledIMMessage(body, nil, when);
        check([m isKindOfClass:[SendLaterMessage class]], @"the builder returns an IMMessage");
        check([m.time isEqualToDate:when], @"the message time is the delivery date");
        check(m.scheduleType == 2 && m.scheduleState == 1,
              @"the message is marked scheduled (type 2, state 1) as Apple's constructor does");
        check([m.text.string isEqualToString:@"see you at nine"], @"the body is kept");

        if (failures) return 1;
        printf("SendLaterTests passed\n");
        return 0;
    }
}
