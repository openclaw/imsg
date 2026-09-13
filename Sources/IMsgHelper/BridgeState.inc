#pragma mark - Constants

// v1 (legacy) single-file IPC paths.
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
// Single-owner guard. Unlike the ready marker above, nothing ever unlinks
// this file: flock ownership is tied to the inode, and a fresh inode would let
// two processes each hold "the" lock.
static NSString *kOwnerLockFile = nil; // .imsg-bridge-owner.lock

// v2 queue-directory IPC paths.
static NSString *kRpcDir = nil;       // .imsg-rpc/
static NSString *kRpcInDir = nil;     // .imsg-rpc/in/
static NSString *kRpcOutDir = nil;    // .imsg-rpc/out/
static NSString *kEventsFile = nil;   // .imsg-events.jsonl
static NSString *kEventsRotated = nil;// .imsg-events.jsonl.1

// Diagnostic file logger. Unified logging redacts NSLog output from inside
// system app processes on macOS 26, which makes diagnosing handler behavior
// from outside the dylib painful. Append-only file in the sandbox container
// gives us a stable channel that's readable from outside.
static NSString *kDebugLogFile = nil; // .imsg-bridge.log

static NSTimer *fileWatchTimer = nil;
static NSTimer *rpcInboxTimer = nil;
static BOOL bridgeDidBootstrap = NO;
static os_unfair_lock eventsLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock trackedMessageGuidLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *trackedMessageGuids = nil;
static int lockFd = -1;
static int ownerLockFd = -1;
// Set once this process has lost the ownership race and is waiting to take
// over. Only affects logging: the first stand-down and the eventual takeover
// are worth a line each, the retries in between are not.
static BOOL bridgeStandingBy = NO;
static const NSTimeInterval kOwnershipRetryInterval = 1.0;

static const NSUInteger kEventsRotateBytes = 1 * 1024 * 1024;
static const NSTimeInterval kV2ClaimMaxAge = 10 * 60;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Messages.app runs in a container; NSHomeDirectory() resolves to
        // ~/Library/Containers/com.apple.MobileSMS/Data inside the sandbox.
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge-ready"];
        kOwnerLockFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge-owner.lock"];
        kRpcDir = [containerPath stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kEventsFile = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl.1"];
        kDebugLogFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge.log"];
    }
}

/// Append a line to `.imsg-bridge.log` inside the Messages container. NSLog
/// output is redacted by unified logging when emitted from system apps on
/// macOS 26, so this is the only reliable diagnostic channel for behavior
/// inside the injected dylib.
__attribute__((format(NSString, 1, 2)))
static void debugLog(NSString *fmt, ...) {
    if (!kDebugLogFile) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSISO8601DateFormatter *fmtr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmtr = [NSISO8601DateFormatter new]; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [fmtr stringFromDate:[NSDate date]], msg];
    FILE *fp = fopen(kDebugLogFile.UTF8String, "a");
    if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
}

#pragma mark - Path Hardening

// Returns YES if any component of `path` (after tilde expansion and CWD
// resolution for relative paths) is a symbolic link, including the final
// component. Mirrors `SecurePath.hasSymlinkComponent` in IMsgCore: realpath()
// alone isn't enough because macOS rewrites `/tmp` -> `/private/tmp`, breaking
// any "resolved == lexical" check. Walking each component with lstat() and
// rejecting on S_IFLNK is the robust answer.
//
// Used to refuse RPC queue dirs and attachment paths that traverse a symlink
// at any level, closing the same-UID-attacker exfiltration path where someone
// drops a symlink to ~/.ssh/id_rsa or a password-manager DB and has Messages
// send it as an attachment to an attacker-controlled handle.
static NSString *normalizeTrustedSystemAliasPrefix(NSString *path) {
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"/tmp": @"/private/tmp",
        @"/var": @"/private/var",
        @"/etc": @"/private/etc",
    };
    for (NSString *alias in aliases) {
        if ([path isEqualToString:alias]) {
            return aliases[alias];
        }
        NSString *prefix = [alias stringByAppendingString:@"/"];
        if ([path hasPrefix:prefix]) {
            return [aliases[alias] stringByAppendingString:
                [path substringFromIndex:alias.length]];
        }
    }
    return path;
}

static BOOL pathHasSymlinkComponent(NSString *path) {
    NSString *lexicalPath = [path stringByExpandingTildeInPath];
    if (!lexicalPath.isAbsolutePath) {
        lexicalPath = [[[NSFileManager defaultManager] currentDirectoryPath]
            stringByAppendingPathComponent:lexicalPath];
    }
    lexicalPath = normalizeTrustedSystemAliasPrefix(lexicalPath);

    NSArray *components = [lexicalPath pathComponents];
    if (components.count == 0) return NO;

    NSString *cursor = [components.firstObject isEqualToString:@"/"] ? @"/" : @"";
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        cursor = [cursor stringByAppendingPathComponent:component];

        struct stat st;
        if (lstat([cursor fileSystemRepresentation], &st) != 0) {
            continue;
        }
        if (S_ISLNK(st.st_mode)) {
            return YES;
        }
    }
    return NO;
}

static BOOL ensureSecureDirectory(NSString *path, NSError **error) {
    if (pathHasSymlinkComponent(path)) {
        if (error) {
            *error = [NSError errorWithDomain:@"imsg.bridge"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RPC queue path traverses a symlink"
            }];
        }
        return NO;
    }

    NSDictionary *secureMode = @{ NSFilePosixPermissions: @(0700) };
    BOOL ok = [[NSFileManager defaultManager]
        createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:secureMode
                        error:error];
    if (!ok) return NO;
    if (pathHasSymlinkComponent(path)) {
        if (error) {
            *error = [NSError errorWithDomain:@"imsg.bridge"
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RPC queue path traverses a symlink (post-mkdir)"
            }];
        }
        return NO;
    }
    chmod([path fileSystemRepresentation], 0700);
    return YES;
}

