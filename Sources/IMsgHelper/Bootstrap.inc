#pragma mark - Dylib Entry Point

static void bridgeClaimOwnership(void);

// Bridge bootstrap. Intentionally NOT run from the dylib constructor: macOS 26
// tightened dyld initializer ordering for platform/system apps, so touching
// ObjC/Foundation/IMCore at constructor time can execute before libSystem has
// finished bootstrapping ("dyld initialized but libSystem has not") and abort
// Messages.app on launch. injectedInit() only schedules this delayed bootstrap;
// the lock file is written after the watchers are installed below.
static void bridgeBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
            if (![bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
                NSLog(@"[imsg-bridge] Ignoring injected process with bundle %@",
                      bundleIdentifier ?: @"(none)");
                return;
            }
            initFilePaths();
            NSLog(@"[imsg-bridge] Dylib injected into %@",
                  [[NSProcessInfo processInfo] processName]);
            debugLog(@"bootstrap starting in process=%@ pid=%d",
                     [[NSProcessInfo processInfo] processName], getpid());
            bridgeClaimOwnership();
        }
    });
}

/// Claim the bridge before touching any shared state, then activate. A loser
/// must not clear IPC files, rewrite the ready marker, claim requests, or (via
/// injectedCleanup) remove the owner's ready marker on exit. It does not give
/// up either: the launcher kills the old Messages and spawns the new one, and
/// if the old owner is still tearing down when we bootstrap, we would otherwise
/// lose the race once and leave this process alive with no bridge at all. So a
/// loser stands by and retries; when the owner exits, its flock is released and
/// the standby takes over without another relaunch.
static void bridgeActivate(void);
static void bridgeClaimOwnership(void) {
    NSString *failure = nil;
    switch (acquireBridgeOwnership(&failure)) {
    case BridgeOwnershipAcquired:
        if (bridgeStandingBy) {
            bridgeStandingBy = NO;
            NSLog(@"[imsg-bridge] Previous owner exited; taking over the bridge");
            debugLog(@"bridge ownership taken over pid=%d", getpid());
        } else {
            debugLog(@"bridge ownership acquired pid=%d", getpid());
        }
        bridgeDidBootstrap = YES;
        bridgeActivate();
        return;
    case BridgeOwnershipHeldElsewhere:
        if (!bridgeStandingBy) {
            bridgeStandingBy = YES;
            NSLog(@"[imsg-bridge] Standing by: %@", failure);
            debugLog(@"stand by pid=%d: %@", getpid(), failure);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kOwnershipRetryInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            bridgeClaimOwnership();
        });
        return;
    case BridgeOwnershipUnavailable:
        NSLog(@"[imsg-bridge] Bridge disabled: %@", failure);
        debugLog(@"bridge disabled pid=%d: %@", getpid(), failure);
        return;
    }
}

static void bridgeActivate(void) {
    @autoreleasepool {
            // Connect to IMDaemon for full IMCore access
            Class daemonClass = NSClassFromString(@"IMDaemonController");
            if (daemonClass) {
                id daemon = [daemonClass performSelector:@selector(sharedInstance)];
                if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
                    [daemon performSelector:@selector(connectToDaemon)];
                    NSLog(@"[imsg-bridge] Connected to IMDaemon");
                    debugLog(@"connected to IMDaemon");
                } else {
                    NSLog(@"[imsg-bridge] IMDaemonController available but couldn't connect");
                    debugLog(@"IMDaemonController available but couldn't connect");
                }
            } else {
                NSLog(@"[imsg-bridge] IMDaemonController class not found");
                debugLog(@"IMDaemonController class not found");
            }

            NSLog(@"[imsg-bridge] Initializing after delay...");

            // Log IMCore status
            Class registryClass = NSClassFromString(@"IMChatRegistry");
            if (registryClass) {
                id registry = [registryClass performSelector:@selector(sharedInstance)];
                if ([registry respondsToSelector:@selector(allExistingChats)]) {
                    NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                    NSLog(@"[imsg-bridge] IMChatRegistry available with %lu chats",
                          (unsigned long)chats.count);
                    debugLog(@"IMChatRegistry available chats=%lu",
                             (unsigned long)chats.count);
                }
            } else {
                NSLog(@"[imsg-bridge] IMChatRegistry NOT available");
                debugLog(@"IMChatRegistry not available");
            }

            probeSelectors();
            startFileWatcher();
            startV2InboxWatcher();
            registerEventObservers();
            debugLog(@"bootstrap complete");
    }
}

__attribute__((constructor))
static void injectedInit(void) {
    // Keep the constructor tiny: only enqueue onto the main queue with
    // libdispatch. Start the startup delay from that first main-queue turn so
    // bridgeBootstrap cannot become ready to run before Messages services the
    // queue for the first time.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            bridgeBootstrap();
        });
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    if (!bridgeDidBootstrap) return;

    NSLog(@"[imsg-bridge] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (rpcInboxTimer) {
        [rpcInboxTimer invalidate];
        rpcInboxTimer = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
    // Release last so the ready marker is removed while we still own the bridge.
    releaseBridgeOwnership();
}
