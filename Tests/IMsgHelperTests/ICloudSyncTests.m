#import <Foundation/Foundation.h>

static NSString *hooksClassName = @"SyncHooks";

static Class icloudTestClass(NSString *name) {
    if ([name isEqualToString:@"IMCloudKitHooks"]) {
        return hooksClassName ? NSClassFromString(hooksClassName) : Nil;
    }
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString icloudTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures, syncStarts;
static BOOL syncing;
static NSDate *lastSync;

@interface SyncHooks : NSObject
@end
@implementation SyncHooks
+ (id)sharedInstance { return [self new]; }
- (BOOL)isSyncing { return syncing; }
- (NSDate *)lastSyncDate { return lastSync; }
- (void)startUserInitiatedSync {
    syncStarts++;
    syncing = YES;
}
@end

// macOS releases that can report sync state but expose no user-initiated sync.
@interface StatusOnlyHooks : NSObject
@end
@implementation StatusOnlyHooks
+ (id)sharedInstance { return [self new]; }
- (BOOL)isSyncing { return syncing; }
- (NSDate *)lastSyncDate { return lastSync; }
@end

static NSDictionary *invoke(NSString *action) {
    return processV2Envelope(@{@"id": @"icloud-proof", @"action": action, @"params": @{}});
}

static NSDictionary *selectors(void) {
    return handleStatus(0, @{})[@"selectors"];
}

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

int main(void) {
    @autoreleasepool {
        syncing = NO;
        lastSync = [NSDate dateWithTimeIntervalSince1970:1793722643];
        check([selectors()[@"icloudSyncStatus"] boolValue], @"Advertise sync status");
        check([selectors()[@"icloudSync"] boolValue], @"Advertise user-initiated sync");

        NSDictionary *status = invoke(@"get-icloud-sync-status");
        check([status[@"success"] boolValue], @"Status succeeds");
        check([status[@"data"][@"syncing"] isEqual:@NO], @"Status reports idle");
        check([status[@"data"][@"last_sync_at"] isEqualToString:@"2026-11-03T16:17:23Z"],
              @"Status reports ISO8601 last sync");
        check(syncStarts == 0, @"Status never starts a sync");

        NSDictionary *sync = invoke(@"start-icloud-sync");
        check([sync[@"success"] boolValue], @"Sync succeeds");
        check(syncStarts == 1, @"Sync starts exactly once");
        check([sync[@"data"][@"requested"] boolValue], @"Sync reports the request");
        check([sync[@"data"][@"syncing"] isEqual:@YES], @"Sync reports state after starting");

        lastSync = nil;
        status = invoke(@"get-icloud-sync-status");
        check([status[@"data"][@"last_sync_at"] isEqual:[NSNull null]], @"Never-synced is null");

        hooksClassName = @"StatusOnlyHooks";
        syncStarts = 0;
        check([selectors()[@"icloudSyncStatus"] boolValue], @"Status-only hooks advertise status");
        check(![selectors()[@"icloudSync"] boolValue], @"Status-only hooks do not advertise sync");
        check([invoke(@"get-icloud-sync-status")[@"success"] boolValue], @"Status-only status works");
        sync = invoke(@"start-icloud-sync");
        check(![sync[@"success"] boolValue], @"Sync fails closed without startUserInitiatedSync");
        check([sync[@"error"] containsString:@"startUserInitiatedSync"], @"Name the missing selector");
        check([sync[@"delivery_disposition"] isEqualToString:@"not_started"], @"Refusal is not_started");

        hooksClassName = nil;
        check(![selectors()[@"icloudSyncStatus"] boolValue], @"Missing class hides status");
        check(![selectors()[@"icloudSync"] boolValue], @"Missing class hides sync");
        status = invoke(@"get-icloud-sync-status");
        check(![status[@"success"] boolValue] && [status[@"error"] containsString:@"IMCloudKitHooks"],
              @"Status fails closed without IMCloudKitHooks");
        check(syncStarts == 0, @"Nothing starts without the selector");

        printf("Bridge iCloud sync tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
