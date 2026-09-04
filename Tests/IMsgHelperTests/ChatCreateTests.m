// Exercise the actual bridge handlers with in-process IMCore/IDS stand-ins.
// Frameworks linked by AppKit can load IDS too. Give the stand-ins unique
// runtime names so tests cannot call the real IDS controller or collide with it.
#import <Foundation/Foundation.h>
static Class testClassFromString(NSString *name) {
    if ([@[@"IMAccountController", @"IMHandleRegistrar", @"IMChatRegistry", @"IDSIDQueryController"]
            containsObject:name]) {
        return NSClassFromString([@"Test" stringByAppendingString:name]);
    }
    return NSClassFromString(name);
}
#define IMAccountController TestIMAccountController
#define IMHandleRegistrar TestIMHandleRegistrar
#define IMChatRegistry TestIMChatRegistry
#define IDSIDQueryController TestIDSIDQueryController
#define NSClassFromString testClassFromString
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

@interface TestHandle : NSObject
@property NSString *ID;
@property NSString *serviceName;
@end
@implementation TestHandle
@end

static NSMutableDictionary *registeredHandles;
static NSMutableArray *createdAddresses;
static NSMutableArray *queriedDestinations;
static NSArray *chatHandles;
static NSArray *invitedHandles;
static NSDictionary *availability;
static NSString *unvendableAddress;
static NSDictionary *canonicalAddresses;
static BOOL accountAvailable;
static BOOL queryThrows;
static BOOL secondaryLookup;
static NSUInteger failures;

static TestHandle *testHandle(NSString *address, NSString *service) {
    TestHandle *handle = [TestHandle new];
    handle.ID = address;
    handle.serviceName = service;
    return handle;
}

@interface TestAccount : NSObject
- (id)imHandleWithID:(NSString *)address;
@end
@implementation TestAccount
- (id)imHandleWithID:(NSString *)address {
    [createdAddresses addObject:address];
    return [address isEqual:unvendableAddress] ? nil
        : testHandle(canonicalAddresses[address] ?: address, @"iMessage");
}
@end

@implementation IMAccountController
+ (instancetype)sharedInstance { return [self new]; }
- (IMAccount *)activeIMessageAccount {
    return accountAvailable ? (IMAccount *)[TestAccount new] : nil;
}
@end

@implementation IMHandleRegistrar
+ (instancetype)sharedInstance { return [self new]; }
- (id)IMHandleWithID:(NSString *)address {
    return secondaryLookup ? nil : registeredHandles[address];
}
- (id)getIMHandlesForID:(NSString *)address {
    return registeredHandles[address];
}
@end

@interface TestChat : NSObject
- (NSString *)guid;
- (void)inviteParticipants:(NSArray *)handles reason:(NSInteger)reason;
@end
@implementation TestChat
- (NSString *)guid { return @"iMessage;+;chat-test"; }
- (void)inviteParticipants:(NSArray *)handles reason:(NSInteger)reason {
    invitedHandles = handles;
}
@end

@implementation IMChatRegistry
+ (instancetype)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    return [guid isEqual:@"iMessage;+;chat-test"] ? [TestChat new] : nil;
}
- (id)chatForIMHandle:(id)handle { return [self chatForIMHandles:@[handle]]; }
- (id)chatForIMHandles:(NSArray *)handles {
    chatHandles = handles;
    return [TestChat new];
}
@end

@implementation IDSIDQueryController
+ (instancetype)sharedInstance { return [self new]; }
- (NSInteger)_currentIDStatusForDestination:(NSString *)destination
                                    service:(NSString *)service
                                 listenerID:(NSString *)listenerID {
    if (queryThrows) [NSException raise:@"TestQueryFailure" format:@"IDS lookup failed"];
    NSCAssert([service isEqual:@"com.apple.madrid"], @"Must query the iMessage service");
    [queriedDestinations addObject:destination];
    return [availability[destination] integerValue];
}
@end

static void resetFixture(void) {
    registeredHandles = [NSMutableDictionary dictionary];
    createdAddresses = [NSMutableArray array];
    queriedDestinations = [NSMutableArray array];
    chatHandles = nil;
    invitedHandles = nil;
    availability = @{@"tel:+15550100101": @1, @"tel:+15550100102": @1,
                     @"mailto:new@example.test": @1};
    unvendableAddress = nil;
    canonicalAddresses = @{};
    accountAvailable = YES;
    queryThrows = NO;
    secondaryLookup = NO;
}

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static NSDictionary *createChat(NSArray *addresses) {
    return handleCreateChat(1, @{@"addresses": addresses, @"service": @"iMessage"});
}

static void checkFailure(NSDictionary *result, NSString *message) {
    check(![result[@"success"] boolValue], message);
    check(chatHandles == nil, @"Must not create a partial chat on failure");
}

int main(void) {
    @autoreleasepool {
        resetFixture();
        NSArray *addresses = @[@"+15550100101", @"+15550100102"];
        NSDictionary *result = createChat(addresses);
        check([result[@"success"] boolValue], @"Two never-contacted addresses must create a chat");
        check([createdAddresses isEqual:addresses], @"Missing handles must be created by the active account");
        check([[chatHandles valueForKey:@"ID"] isEqual:addresses], @"The chat must contain both requested handles");
        check(queriedDestinations.count == 2, @"Check both recipients with IDS before chat creation");

        for (NSNumber *useSecondary in @[@NO, @YES]) {
            resetFixture();
            secondaryLookup = useSecondary.boolValue;
            id cached = testHandle(addresses[0], @"iMessage");
            registeredHandles[addresses[0]] = secondaryLookup ? [NSSet setWithObject:cached] : cached;
            result = createChat(@[addresses[0]]);
            check([result[@"success"] boolValue] && chatHandles.firstObject == cached,
                  @"Both registrar selectors must preserve cached handles");
            check(createdAddresses.count == 0, @"The registrar remains the fast path");
        }

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"SMS");
        result = createChat(@[addresses[0]]);
        check([result[@"success"] boolValue], @"An SMS-only cached handle must allow iMessage creation");
        check([[(TestHandle *)chatHandles.firstObject serviceName] isEqual:@"iMessage"],
              @"Never create an iMessage chat with an SMS handle");

        resetFixture();
        result = createChat(@[@"new@example.test"]);
        check([result[@"success"] boolValue], @"Unknown email addresses must also work");
        check([queriedDestinations isEqual:@[@"mailto:new@example.test"]], @"Email IDS queries use mailto");

        resetFixture();
        canonicalAddresses = @{@"(555) 010-0101": addresses[0]};
        result = createChat(@[@"(555) 010-0101"]);
        check([result[@"success"] boolValue], @"Check the account-canonicalized address with IDS");
        check([queriedDestinations isEqual:@[@"tel:+15550100101"]], @"IDS must receive the canonical phone number");

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"iMessage");
        unvendableAddress = addresses[1];
        checkFailure(createChat(addresses), @"A missing second handle must fail instead of creating a direct chat");

        resetFixture();
        accountAvailable = NO;
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"SMS");
        checkFailure(createChat(@[addresses[0]]), @"No iMessage account must not fall back to SMS");

        for (NSNumber *idStatus in @[@0, @2]) {
            resetFixture();
            availability = @{@"tel:+15550100101": @1, @"tel:+15550100102": idStatus};
            for (NSString *address in addresses) {
                registeredHandles[address] = testHandle(address, @"iMessage");
            }
            result = createChat(addresses);
            checkFailure(result, @"Unconfirmed recipients must fail before creating a chat");
            check([result[@"error"] containsString:addresses[1]], @"The error must identify the failing address");
            check([result[@"error"] containsString:idStatus.integerValue == 2 ? @"not reachable" : @"could not confirm"],
                  @"Distinguish unreachable addresses from unresolved IDS status");
        }

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"iMessage");
        queryThrows = YES;
        checkFailure(createChat(@[addresses[0]]), @"IDS errors must stop chat creation");

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"iMessage");
        checkFailure(createChat(@[addresses[0], @42]), @"Invalid addresses must not be silently omitted");

        resetFixture();
        result = handleCreateChat(1, @{@"addresses": @[addresses[0]], @"service": @"SMS"});
        checkFailure(result, @"Explicit SMS creation must not create an iMessage handle");
        check(createdAddresses.count == 0, @"SMS lookup must not use the iMessage account");

        for (NSNumber *idStatus in @[@0, @1, @2]) {
            resetFixture();
            availability = @{@"tel:+15550100101": idStatus};
            result = handleAddParticipant(1, @{
                @"chatGuid": @"iMessage;+;chat-test", @"address": addresses[0]
            });
            if (idStatus.integerValue == 1) {
                check([result[@"success"] boolValue], @"Reachable first-contact participants can be invited");
                check([[invitedHandles valueForKey:@"ID"] isEqual:@[addresses[0]]],
                      @"Invite the account-created participant");
            } else {
                check(![result[@"success"] boolValue], @"Reject unconfirmed first-contact invitations");
                check(invitedHandles == nil, @"IDS negative/unknown results must never reach the invitation selector");
                check([result[@"error"] containsString:addresses[0]], @"Invitation errors identify the recipient");
            }
        }

        resetFixture();
        queryThrows = YES;
        result = handleAddParticipant(1, @{@"chatGuid": @"iMessage;+;chat-test", @"address": addresses[0]});
        check(![result[@"success"] boolValue] && invitedHandles == nil,
              @"An IDS error must stop participant invitation");

        resetFixture();
        check(resolveChatByGuid(@"iMessage;-;+15550100101") == nil,
              @"Generic direct GUID resolution must not create a first-contact chat");
        check(createdAddresses.count == 0 && chatHandles == nil,
              @"Lookup-only commands must not create handles or chats for unknown recipients");

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"iMessage");
        check(resolveChatByGuid(@"iMessage;-;+15550100101") != nil,
              @"Generic direct GUID resolution still materializes registered handles");
        check([[chatHandles valueForKey:@"ID"] isEqual:@[addresses[0]]],
              @"Registered direct resolution preserves the requested participant");

        resetFixture();
        registeredHandles[addresses[0]] = testHandle(addresses[0], @"SMS");
        check(resolveChatByGuid(@"iMessage;-;+15550100101") == nil && chatHandles == nil,
              @"Direct iMessage resolution must not fall back to a registered SMS handle");

        fprintf(stdout, "Bridge chat-create tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
