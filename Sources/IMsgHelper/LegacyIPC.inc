#pragma mark - File-based IPC

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData
                                                                options:0
                                                                  error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        NSDictionary *result = processCommand(command);

        if (result != nil) {
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];

            // Clear command file to signal processing is complete
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

            NSLog(@"[imsg-bridge] Processed command, wrote response");
        }
    }
}

/// The ready marker tells the launcher and CLI that an injected helper is up.
/// Only the bridge owner writes it (see acquireBridgeOwnership).
static void writeReadyMarker(void) {
    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0644);
    if (lockFd >= 0) {
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }
}

/// The launcher removes the ready marker before it spawns a replacement. If
/// this owner survived that (killall missed it), the replacement stands by and
/// nobody would ever write a marker again: the launcher times out even though
/// the bridge is serving. Keep readiness truthful by restoring the marker
/// while we hold ownership; the standby takes over the moment we exit.
static void reassertReadyMarker(void) {
    if (ownerLockFd < 0) return;
    if (access(kLockFile.UTF8String, F_OK) == 0) return;
    writeReadyMarker();
    NSLog(@"[imsg-bridge] Ready marker was removed while owning the bridge; restored it");
    debugLog(@"ready marker restored pid=%d", getpid());
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-bridge] Starting file-based IPC");
    NSLog(@"[imsg-bridge] Command file: %@", kCommandFile);
    NSLog(@"[imsg-bridge] Response file: %@", kResponseFile);

    // Create/clear IPC files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file with PID to indicate we're ready
    writeReadyMarker();

    // Poll command file via NSTimer on the main run loop.
    // NSTimer survives reliably in injected dylib contexts (dispatch_source timers
    // can get deallocated).
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager]
                                   attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;

    NSLog(@"[imsg-bridge] File watcher started, ready for commands");
}

