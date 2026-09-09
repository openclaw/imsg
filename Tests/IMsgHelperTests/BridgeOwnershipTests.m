// Exercise the single-owner guard: exactly one injected helper per container may
// service the bridge queues, a loser must stand down without touching shared
// state, and the owner's lock must survive the ready marker being removed.
#import <Foundation/Foundation.h>
#import <sys/file.h>
#import <sys/stat.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

static NSUInteger failures;
static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static NSString *contentsOf(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

/// Stand in for a second injected instance: a separate open file description
/// on the same lock path. flock ownership is per description, so this conflicts
/// with the helper's descriptor exactly as another process would.
static int competitorHold(NSString *path, pid_t pretendPID) {
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    check(fd >= 0, @"Competitor opens the owner lock");
    check(flock(fd, LOCK_EX | LOCK_NB) == 0, @"Competitor takes the owner lock");
    NSString *pid = [NSString stringWithFormat:@"%d", pretendPID];
    check(ftruncate(fd, 0) == 0 && pwrite(fd, pid.UTF8String, pid.length, 0) == (ssize_t)pid.length,
          @"Competitor records its pid");
    return fd;
}

static void competitorRelease(int fd) {
    if (fd < 0) return;
    flock(fd, LOCK_UN);
    close(fd);
}

static BOOL competitorCanLock(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
    if (fd < 0) return NO;
    BOOL locked = flock(fd, LOCK_EX | LOCK_NB) == 0;
    competitorRelease(fd);
    return locked;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        check([files createDirectoryAtPath:home withIntermediateDirectories:YES
                               attributes:@{NSFilePosixPermissions: @0700} error:nil],
              @"Create isolated container");

        // Bind every container path to the fixture so nothing touches Messages.
        kCommandFile = [home stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [home stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [home stringByAppendingPathComponent:@".imsg-bridge-ready"];
        kOwnerLockFile = [home stringByAppendingPathComponent:@".imsg-bridge-owner.lock"];
        kRpcDir = [home stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kEventsFile = [home stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [home stringByAppendingPathComponent:@".imsg-events.jsonl.1"];
        kDebugLogFile = [home stringByAppendingPathComponent:@".imsg-bridge.log"];

        // 1. First helper becomes the owner and records its pid.
        NSString *failure = nil;
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipAcquired, @"First helper acquires ownership");
        check(failure == nil, @"Successful acquisition reports no failure");
        check(ownerLockFd >= 0, @"Owner keeps the lock descriptor open");
        check([contentsOf(kOwnerLockFile) isEqualToString:[NSString stringWithFormat:@"%d", getpid()]],
              @"Owner lock records the owner pid");
        struct stat info;
        check(stat(kOwnerLockFile.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600,
              @"Owner lock is owner-only");
        check(!competitorCanLock(kOwnerLockFile), @"A second instance cannot take the lock while it is held");

        // 2. Release hands the lock over without unlinking it, so the inode stays stable.
        releaseBridgeOwnership();
        check(ownerLockFd == -1, @"Release closes the descriptor");
        check([files fileExistsAtPath:kOwnerLockFile], @"Release leaves the lock file in place");
        check(competitorCanLock(kOwnerLockFile), @"A second instance can take the lock after release");

        // 3. Second helper: another instance owns the bridge. Stand down, and
        //    leave the survivor's ready marker and lock contents untouched.
        check([@"4242" writeToFile:kLockFile atomically:NO encoding:NSUTF8StringEncoding error:nil],
              @"Seed the survivor's ready marker");
        int competitor = competitorHold(kOwnerLockFile, 4242);
        failure = nil;
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipHeldElsewhere,
              @"Second helper sees the lock held by a live instance");
        check(ownerLockFd == -1, @"Standing down keeps no descriptor");
        check([failure containsString:@"4242"], @"Stand-down names the owning pid");
        check([contentsOf(kOwnerLockFile) isEqualToString:@"4242"], @"Standing down leaves the owner's pid");
        check([contentsOf(kLockFile) isEqualToString:@"4242"], @"Standing down leaves the ready marker");

        // 4. A stood-down helper never bootstrapped, so its destructor must not
        //    remove the owner's ready marker.
        bridgeDidBootstrap = NO;
        injectedCleanup();
        check([contentsOf(kLockFile) isEqualToString:@"4242"], @"Loser cleanup leaves the ready marker");
        check([files fileExistsAtPath:kOwnerLockFile], @"Loser cleanup leaves the owner lock");
        competitorRelease(competitor);

        // 5. The owner's cleanup removes its own ready marker and releases the
        //    lock, but keeps the lock file so the next owner locks the same inode.
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipAcquired,
              @"Helper re-acquires after the other instance exits");
        bridgeDidBootstrap = YES;
        check([[NSString stringWithFormat:@"%d", getpid()] writeToFile:kLockFile atomically:NO
                                                              encoding:NSUTF8StringEncoding error:nil],
              @"Owner writes its ready marker");
        injectedCleanup();
        check(![files fileExistsAtPath:kLockFile], @"Owner cleanup removes its ready marker");
        check(ownerLockFd == -1, @"Owner cleanup releases the lock");
        check([files fileExistsAtPath:kOwnerLockFile], @"Owner cleanup keeps the lock file");
        check(competitorCanLock(kOwnerLockFile), @"The next instance can take the lock after owner cleanup");
        bridgeDidBootstrap = NO;

        // 6. Tampered lock paths are refused rather than trusted.
        check([files removeItemAtPath:kOwnerLockFile error:nil], @"Remove lock for the symlink case");
        NSString *target = [home stringByAppendingPathComponent:@"elsewhere"];
        check([@"" writeToFile:target atomically:NO encoding:NSUTF8StringEncoding error:nil],
              @"Create symlink target");
        check(symlink(target.fileSystemRepresentation, kOwnerLockFile.fileSystemRepresentation) == 0,
              @"Plant a symlink at the lock path");
        failure = nil;
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipUnavailable, @"A symlinked lock path is refused");
        check(ownerLockFd == -1 && failure.length > 0, @"Symlink refusal reports why");
        check([files removeItemAtPath:kOwnerLockFile error:nil], @"Remove symlink");

        check(acquireBridgeOwnership(&failure) == BridgeOwnershipAcquired, @"Re-create a regular lock file");
        releaseBridgeOwnership();
        NSString *hardlink = [home stringByAppendingPathComponent:@"hardlink"];
        check(link(kOwnerLockFile.fileSystemRepresentation, hardlink.fileSystemRepresentation) == 0,
              @"Plant a hard link to the lock");
        failure = nil;
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipUnavailable,
              @"A multiply linked lock file is refused");
        check(ownerLockFd == -1, @"Hard-link refusal keeps no descriptor");
        check([files removeItemAtPath:hardlink error:nil], @"Remove hard link");
        check(acquireBridgeOwnership(&failure) == BridgeOwnershipAcquired,
              @"Lock works again once the extra link is gone");
        releaseBridgeOwnership();

        // 7. Real claim path: a helper that loses the race stands by without
        //    touching shared state, then takes over once the owner exits.
        check([@"4242" writeToFile:kLockFile atomically:NO encoding:NSUTF8StringEncoding error:nil],
              @"Seed the owner's ready marker again");
        competitor = competitorHold(kOwnerLockFile, 4242);
        bridgeClaimOwnership();
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        check(!bridgeDidBootstrap, @"Standby has not bootstrapped");
        check(bridgeStandingBy, @"Loser is standing by");
        check(rpcInboxTimer == nil, @"Standby runs no inbox watcher");
        check([contentsOf(kLockFile) isEqualToString:@"4242"], @"Standby leaves the owner's ready marker");
        check(![files fileExistsAtPath:kRpcInDir], @"Standby creates no queue directories");

        competitorRelease(competitor);
        [[NSRunLoop mainRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:kOwnershipRetryInterval + 0.5]];
        check(bridgeDidBootstrap, @"Standby takes over after the owner exits");
        check(!bridgeStandingBy, @"Takeover clears the standby flag");
        check(ownerLockFd >= 0, @"Takeover holds the owner lock");
        check(rpcInboxTimer != nil, @"Takeover starts the inbox watcher");
        check([contentsOf(kLockFile) isEqualToString:[NSString stringWithFormat:@"%d", getpid()]],
              @"Takeover writes its own ready marker");
        check([files fileExistsAtPath:kRpcInDir], @"Takeover provisions the queue directories");

        // 8. A launcher that missed this owner on kill deletes the ready marker
        //    before spawning a standby. The owner restores it so the launcher
        //    sees a truthful readiness state instead of timing out.
        check([files removeItemAtPath:kLockFile error:nil], @"Launcher removes the ready marker");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        check([contentsOf(kLockFile) isEqualToString:[NSString stringWithFormat:@"%d", getpid()]],
              @"Owner restores its ready marker within a second");
        injectedCleanup();
        check(![files fileExistsAtPath:kLockFile] && ownerLockFd == -1, @"Cleanup after takeover releases everything");

        [files removeItemAtPath:home error:nil];
        if (failures) {
            fprintf(stderr, "%lu bridge ownership check(s) failed\n", (unsigned long)failures);
            return 1;
        }
        printf("bridge ownership tests passed\n");
        return 0;
    }
}
