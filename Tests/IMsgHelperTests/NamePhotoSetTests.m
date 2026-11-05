#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <pwd.h>

static NSString *fixtureHome;
static BOOL settersAvailable = YES;
static BOOL daemonAvailable = YES;
static BOOL daemonThrows;
static NSUInteger setCalls;
static NSUInteger sharingCalls;
static id personalNickname;

@protocol FixtureNicknameDaemon
- (void)setNewPersonalNickname:(id)nickname;
@end

static struct passwd *fixturePassword(uid_t uid) {
    static struct passwd fixture;
    struct passwd *entry = getpwuid(uid);
    if (!entry) return NULL;
    fixture = *entry;
    if (fixtureHome) fixture.pw_dir = (char *)fixtureHome.fileSystemRepresentation;
    return &fixture;
}

static Class fixtureClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMNickname": @"SetNickname", @"IMNicknameAvatarImage": @"SetAvatar",
        @"IMNicknameController": @"SetController", @"IMDaemonController": @"SetDaemon",
        @"IMMeCardSharingStateController": @"SetSharing"
    };
    if ([name isEqual:@"IMNickname"] && !settersAvailable) return Nil;
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}

static Protocol *fixtureProtocol(NSString *name) {
    if ([name isEqual:@"IMDaemonAnyProtocol"]) return @protocol(FixtureNicknameDaemon);
    return NSProtocolFromString(name);
}

#define getpwuid fixturePassword
#define NSClassFromString fixtureClass
#define NSProtocolFromString fixtureProtocol
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSProtocolFromString
#undef NSClassFromString
#undef getpwuid

@interface SetNickname : NSObject
@property NSString *firstName;
@property NSString *lastName;
@property id avatar;
@end
@implementation SetNickname
- (id)initWithFirstName:(NSString *)firstName lastName:(NSString *)lastName
                 avatar:(id)avatar pronouns:(id)pronouns {
    if ((self = [super init])) {
        self.firstName = firstName;
        self.lastName = lastName;
        self.avatar = avatar;
    }
    return self;
}
@end

@interface SetAvatar : NSObject
@property NSString *imageName;
@property NSString *imageFilePath;
@end
@implementation SetAvatar
- (id)initWithImageName:(NSString *)name imageFilePath:(NSString *)path
     sensitivityAnalysis:(id)analysis {
    if ((self = [super init])) { self.imageName = name; self.imageFilePath = path; }
    return self;
}
@end

@interface SetController : NSObject
@end
@implementation SetController
+ (id)sharedInstance { return [self new]; }
- (BOOL)isInitialLoadComplete { return YES; }
- (id)personalNickname { return personalNickname; }
@end

@interface SetSharing : NSObject
@end
@implementation SetSharing
- (void)setSharingEnabled:(BOOL)enabled { sharingCalls++; }
@end

@interface SetDaemon : NSObject <FixtureNicknameDaemon>
@end
@implementation SetDaemon
+ (id)sharedController { return [self new]; }
- (id)remoteDaemon { return daemonAvailable ? self : nil; }
- (void)setNewPersonalNickname:(id)nickname {
    if (daemonThrows) [NSException raise:@"FixtureFailure" format:@"No request accepted"];
    setCalls++;
    personalNickname = nickname;
}
@end

static NSUInteger failures;
static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static void checkRefused(NSDictionary *params) {
    NSUInteger previousSetCalls = setCalls;
    NSUInteger previousSharingCalls = sharingCalls;
    NSDictionary *result = handleSetPersonalNickname(1, params);
    check(![result[@"success"] boolValue], @"Invalid or unavailable set is refused");
    check(setCalls == previousSetCalls && sharingCalls == previousSharingCalls,
          @"Refusal does not mutate the nickname or sharing setting");
}

int main(void) {
    @autoreleasepool {
        fixtureHome = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *staging = [fixtureHome stringByAppendingPathComponent:@"Library/Messages/Attachments/imsg"];
        [[NSFileManager defaultManager] createDirectoryAtPath:staging
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *photo = [staging stringByAppendingPathComponent:@"avatar.jpg"];
        [@"synthetic avatar bytes" writeToFile:photo atomically:YES encoding:NSUTF8StringEncoding error:nil];

        check(personalNicknameSetAvailable(), @"Fixture exposes the setter capability");
        handleStatus(1, @{});
        check(setCalls == 0 && sharingCalls == 0, @"Capability inspection never sets identity");

        for (NSDictionary *params in @[
            @{}, @{@"firstName": @1}, @{@"firstName": @"Ada", @"lastName": @1},
            @{@"firstName": @"Ada", @"photoPath": [NSNull null]},
            @{@"firstName": @"Ada", @"sharingEnabled": @1},
            @{@"firstName": @"Ada", @"sharingEnabled": [NSNull null]},
            @{@"firstName": @"Ada", @"photoPath": @"/outside/avatar.jpg"}
        ]) checkRefused(params);

        settersAvailable = NO;
        checkRefused(@{@"firstName": @"Ada", @"sharingEnabled": @YES});
        settersAvailable = YES;
        daemonAvailable = NO;
        checkRefused(@{@"firstName": @"Ada", @"sharingEnabled": @YES});
        daemonAvailable = YES;
        daemonThrows = YES;
        checkRefused(@{@"firstName": @"Ada", @"sharingEnabled": @YES});
        daemonThrows = NO;

        NSDictionary *result = handleSetPersonalNickname(1, @{@"firstName": @"Ada", @"lastName": @""});
        check([result[@"success"] boolValue] && [result[@"stored"] boolValue],
              @"Explicit setter observes the synthetic daemon echo");
        check([(SetNickname *)personalNickname lastName] == nil,
              @"Empty last name is omitted from the record");
        check([(SetNickname *)personalNickname avatar] == nil,
              @"Omitted photo produces a name-only record");

        NSUInteger previousSharingCalls = sharingCalls;
        result = handleSetPersonalNickname(1, @{
            @"firstName": @"Ada", @"lastName": @"Lovelace", @"photoPath": photo, @"sharingEnabled": @NO
        });
        check([result[@"success"] boolValue] && [result[@"stored"] boolValue],
              @"Explicit photo setter observes the synthetic daemon echo");
        SetAvatar *avatar = [(SetNickname *)personalNickname avatar];
        check([avatar.imageName isEqual:@"NickNameImage"] && [avatar.imageFilePath isEqual:photo],
              @"Record uses the native avatar name and staged fixture path");
        check(sharingCalls == previousSharingCalls + 1, @"Explicit sharing setting is applied once");
        check(result[@"has_photo"] && CFGetTypeID((__bridge CFTypeRef)result[@"has_photo"]) == CFBooleanGetTypeID(),
              @"Photo presence is a JSON boolean");

        [[NSFileManager defaultManager] removeItemAtPath:fixtureHome error:nil];
        printf("Bridge Name & Photo setter tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
