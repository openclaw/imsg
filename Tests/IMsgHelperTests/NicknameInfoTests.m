#import <Foundation/Foundation.h>

static Class nicknameTestClass(NSString *name) {
    NSDictionary *classes = @{@"IMAccountController": @"NicknameAccountController",
                              @"IMNicknameController": @"NicknameController"};
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString nicknameTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;
static id currentNickname;

@interface NicknameAvatar : NSObject
@property NSString *imageFilePath;
@property BOOL contentIsSensitive;
@property BOOL imageExists;
@end
@implementation NicknameAvatar
@end

@interface NicknameRecord : NSObject
@property NSString *firstName;
@property NSString *lastName;
@property NSString *displayName;
@property id avatar;
@end
@implementation NicknameRecord
@end

@interface NicknameLegacyRecord : NSObject
@end
@implementation NicknameLegacyRecord
- (NSString *)description { return @"<NicknameLegacyRecord>"; }
@end

@interface NicknameAccount : NSObject
@end
@implementation NicknameAccount
- (id)imHandleWithID:(NSString *)handleID { return handleID; }
@end

@interface NicknameAccountController : NSObject
@end
@implementation NicknameAccountController
+ (id)sharedInstance { return [self new]; }
- (id)activeIMessageAccount { return [NicknameAccount new]; }
@end

@interface NicknameController : NSObject
@end
@implementation NicknameController
+ (id)sharedInstance { return [self new]; }
- (id)nicknameForHandle:(id)handle { return currentNickname; }
@end

static NSDictionary *invokeNickname(id nickname) {
    currentNickname = nickname;
    NSDictionary *response = processV2Envelope(@{
        @"id": @"nickname-proof",
        @"action": @"get-nickname-info",
        @"params": @{@"address": @"+15551234567"}
    });
    return [response[@"success"] boolValue] ? response[@"data"] : nil;
}

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

int main(void) {
    @autoreleasepool {
        NicknameAvatar *avatar = [NicknameAvatar new];
        avatar.imageFilePath = @"/tmp/NickNameCache/record-ad";
        avatar.contentIsSensitive = YES;
        avatar.imageExists = YES;
        NicknameRecord *full = [NicknameRecord new];
        full.firstName = @"Jane";
        full.lastName = @"Appleseed";
        full.displayName = @"Jane Appleseed";
        full.avatar = avatar;
        NSDictionary *info = invokeNickname(full);
        check([info[@"has_nickname"] boolValue], @"Full nickname is found");
        check([info[@"first_name"] isEqualToString:@"Jane"], @"Return first name");
        check([info[@"last_name"] isEqualToString:@"Appleseed"], @"Return last name");
        check([info[@"display_name"] isEqualToString:@"Jane Appleseed"], @"Return display name");
        check([info[@"avatar_path"] isEqualToString:@"/tmp/NickNameCache/record-ad"], @"Return avatar path");
        check([info[@"avatar_is_sensitive"] boolValue], @"Return avatar sensitivity");
        check([info[@"description"] length] > 0, @"Keep description");

        NicknameRecord *partial = [NicknameRecord new];
        partial.firstName = @"Jane";
        partial.lastName = @"";
        NicknameAvatar *plainAvatar = [NicknameAvatar new];
        plainAvatar.imageFilePath = @"/tmp/NickNameCache/record-ad";
        plainAvatar.imageExists = YES;
        partial.avatar = plainAvatar;
        info = invokeNickname(partial);
        check([info[@"first_name"] isEqualToString:@"Jane"], @"Return partial first name");
        check(!info[@"last_name"] && !info[@"display_name"], @"Omit empty and missing names");
        check([info[@"avatar_is_sensitive"] isEqual:@NO], @"Return non-sensitive avatar as false");

        NicknameAvatar *missingPath = [NicknameAvatar new];
        missingPath.imageExists = YES;
        NicknameAvatar *notDownloaded = [NicknameAvatar new];
        notDownloaded.imageFilePath = @"/tmp/NickNameCache/record-ad";
        for (NicknameAvatar *unusable in @[missingPath, notDownloaded]) {
            partial.avatar = unusable;
            info = invokeNickname(partial);
            check(!info[@"avatar_path"] && !info[@"avatar_is_sensitive"], @"Omit avatar without a file");
        }

        info = invokeNickname([NicknameLegacyRecord new]);
        check([info[@"has_nickname"] boolValue], @"Legacy nickname is found");
        check([info[@"description"] isEqualToString:@"<NicknameLegacyRecord>"], @"Legacy nickname keeps description");
        check(!info[@"first_name"] && !info[@"avatar_path"], @"Legacy nickname omits unknown selectors");

        info = invokeNickname(nil);
        check(info && ![info[@"has_nickname"] boolValue], @"Missing nickname reports none");
        check(!info[@"description"] && !info[@"first_name"], @"Missing nickname has no fields");

        printf("Bridge nickname-info tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
