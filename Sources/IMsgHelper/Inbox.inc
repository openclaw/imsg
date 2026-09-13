#pragma mark - v2 Inbox Watcher

/// Process a single inbox file end-to-end: claim, read, dispatch, write outbox,
/// remove claim. The same-directory rename is the cross-process ownership
/// boundary: only one injected process can remove the finalized request name.
static void processV2InboxFile(NSString *uuid) {
    @autoreleasepool {
        NSString *inPath = [kRpcInDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];
        NSString *claimName = [NSString stringWithFormat:@"%@.processing.%d", uuid, getpid()];
        NSString *claimPath = [kRpcInDir stringByAppendingPathComponent:claimName];
        NSString *outPath = [kRpcOutDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];

        if (rename(inPath.UTF8String, claimPath.UTF8String) != 0) {
            int claimErrno = errno;
            // ENOENT is the expected race loser: another injected process
            // already claimed this request. Other failures leave the finalized
            // file in place for a later scan instead of risking duplicate work.
            if (claimErrno != ENOENT) {
                NSLog(@"[imsg-bridge v2] Could not claim %@ (errno=%d)", inPath, claimErrno);
                debugLog(@"v2 claim failed id=%@ pid=%d errno=%d",
                         uuid, getpid(), claimErrno);
            }
            return;
        }
        debugLog(@"v2 claimed id=%@ pid=%d process=%@",
                 uuid, getpid(), [[NSProcessInfo processInfo] processName]);

        NSError *err = nil;
        NSData *body = [NSData dataWithContentsOfFile:claimPath options:0 error:&err];
        if (!body || err) {
            NSLog(@"[imsg-bridge v2] Could not read %@: %@", claimPath, err);
            // Remove malformed file so we don't retry forever.
            [[NSFileManager defaultManager] removeItemAtPath:claimPath error:nil];
            return;
        }

        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:body
                                                                 options:0
                                                                   error:&err];
        NSDictionary *response;
        if (!envelope || ![envelope isKindOfClass:[NSDictionary class]]) {
            response = errorResponseV2(uuid, @"Invalid JSON in request");
        } else {
            response = processV2Envelope(envelope);
        }

        NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                               options:0
                                                                 error:&err];
        if (responseData) {
            NSString *tmp = [outPath stringByAppendingPathExtension:@"tmp"];
            [responseData writeToFile:tmp atomically:NO];
            // Atomic rename so the CLI never reads a half-written file.
            rename(tmp.UTF8String, outPath.UTF8String);
        }

        // Drop the claimed request — we're done with it. If the process dies
        // after claiming, a later inbox scan removes the orphan without
        // replaying a potentially delivered side effect.
        [[NSFileManager defaultManager] removeItemAtPath:claimPath error:nil];
    }
}

static pid_t v2ClaimOwnerPID(NSString *name) {
    NSRange marker = [name rangeOfString:@".processing." options:NSBackwardsSearch];
    if (marker.location == NSNotFound) return 0;

    NSString *pidString = [name substringFromIndex:NSMaxRange(marker)];
    NSScanner *scanner = [NSScanner scannerWithString:pidString];
    int value = 0;
    if (![scanner scanInt:&value] || !scanner.isAtEnd || value <= 0) return 0;
    return (pid_t)value;
}

/// Claimed requests are never replayed: the handler may have dispatched its
/// side effect before dying. Delete claims owned by dead processes, claims
/// left by a recycled current PID, and old claims whose PID was reused by an
/// unrelated live process.
static void cleanupOrphanedV2Claims(NSArray *entries) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in entries) {
        pid_t ownerPID = v2ClaimOwnerPID(name);
        if (ownerPID <= 0) continue;

        NSString *path = [kRpcInDir stringByAppendingPathComponent:name];
        BOOL shouldRemove = ownerPID == getpid();
        if (!shouldRemove && kill(ownerPID, 0) != 0 && errno == ESRCH) {
            shouldRemove = YES;
        }
        if (!shouldRemove) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSDate *modified = attrs[NSFileModificationDate];
            shouldRemove =
                modified && [[NSDate date] timeIntervalSinceDate:modified] > kV2ClaimMaxAge;
        }
        if (shouldRemove) {
            [fm removeItemAtPath:path error:nil];
            debugLog(@"v2 removed orphan claim=%@ owner_pid=%d",
                     name, (int)ownerPID);
        }
    }
}

static void scanV2Inbox(void) {
    @autoreleasepool {
        NSError *err = nil;
        NSArray *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:kRpcInDir error:&err];
        if (!entries) return;
        cleanupOrphanedV2Claims(entries);
        for (NSString *name in entries) {
            // Only consume finalized .json files; skip in-flight .tmp.
            if (![name hasSuffix:@".json"]) continue;
            NSString *uuid = [name stringByDeletingPathExtension];
            processV2InboxFile(uuid);
        }
    }
}

static void startV2InboxWatcher(void) {
    initFilePaths();

    // Ensure the queue dirs exist (CLI also pre-creates them, but be defensive
    // in case a v2-only run happened). Mode 0700 keeps other UIDs / sandboxed
    // peers from being able to enumerate or inject RPC requests, and the
    // symlink check refuses to operate if any path component traverses a
    // link, see pathHasSymlinkComponent for rationale.
    NSError *secureDirError = nil;
    if (!ensureSecureDirectory(kRpcDir, &secureDirError) ||
        !ensureSecureDirectory(kRpcInDir, &secureDirError) ||
        !ensureSecureDirectory(kRpcOutDir, &secureDirError)) {
        NSLog(@"[imsg-bridge v2] Refusing insecure RPC queue path: %@",
              secureDirError.localizedDescription);
        return;
    }

    NSLog(@"[imsg-bridge v2] Inbox: %@", kRpcInDir);
    NSLog(@"[imsg-bridge v2] Outbox: %@", kRpcOutDir);

    __block NSUInteger tick = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        scanV2Inbox();
        // Once a second is plenty: this only matters during a relaunch.
        if (++tick % 10 == 0) reassertReadyMarker();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    rpcInboxTimer = timer;

    NSLog(@"[imsg-bridge v2] Inbox watcher started");
}

