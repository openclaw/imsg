#pragma mark - Bridge Ownership

/// Exactly one injected Messages.app per container may service the bridge.
/// The launcher serializes its own launches, but a second injected instance can
/// still arrive another way: a manual launch with DYLD_INSERT_LIBRARIES set, a
/// crash-restart supervisor, or a launcher that predates the launch lock. Two
/// helpers then both clear the legacy IPC files, overwrite each other's pid in
/// the ready marker, both claim from the same v2 inbox, and whichever exits
/// first deletes the survivor's ready marker.
///
/// Ownership is a kernel flock on a dedicated file, so it dies with the process
/// and a crashed owner never wedges the next one. On anything but Acquired,
/// `failure` says why and shared state is left untouched.
typedef NS_ENUM(NSInteger, BridgeOwnership) {
    BridgeOwnershipAcquired,
    /// A live instance holds the lock. Worth retrying: it releases on exit.
    BridgeOwnershipHeldElsewhere,
    /// The lock path is unusable (symlink, wrong owner, extra links, I/O error).
    /// Retrying cannot help.
    BridgeOwnershipUnavailable,
};

static BridgeOwnership acquireBridgeOwnership(NSString **failure) {
    if (ownerLockFd >= 0) return BridgeOwnershipAcquired;

    if (pathHasSymlinkComponent(kOwnerLockFile)) {
        if (failure) *failure = [NSString stringWithFormat:
            @"owner lock path traverses a symlink: %@", kOwnerLockFile];
        return BridgeOwnershipUnavailable;
    }

    int fd = open(kOwnerLockFile.UTF8String, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (failure) *failure = [NSString stringWithFormat:
            @"could not open owner lock %@: %s", kOwnerLockFile, strerror(errno)];
        return BridgeOwnershipUnavailable;
    }

    struct stat info;
    if (fstat(fd, &info) != 0 || info.st_uid != geteuid() || !S_ISREG(info.st_mode) ||
        info.st_nlink != 1 || (info.st_mode & 077) != 0) {
        close(fd);
        if (failure) *failure = [NSString stringWithFormat:
            @"owner lock must be an owner-only regular file: %@", kOwnerLockFile];
        return BridgeOwnershipUnavailable;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int lockErrno = errno;
        pid_t owner = 0;
        if (lockErrno == EWOULDBLOCK) {
            char buf[32] = {0};
            ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);
            if (n > 0) owner = (pid_t)strtol(buf, NULL, 10);
        }
        close(fd);
        if (failure) {
            *failure = owner > 0
                ? [NSString stringWithFormat:
                    @"another injected instance (pid %d) already owns the bridge", (int)owner]
                : [NSString stringWithFormat:
                    @"could not acquire owner lock %@: %s", kOwnerLockFile, strerror(lockErrno)];
        }
        return lockErrno == EWOULDBLOCK ? BridgeOwnershipHeldElsewhere
                                        : BridgeOwnershipUnavailable;
    }

    // Diagnostics only: the flock is the ownership, the pid is for humans.
    NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
    if (ftruncate(fd, 0) == 0) {
        pwrite(fd, pidStr.UTF8String, pidStr.length, 0);
    }
    ownerLockFd = fd;
    return BridgeOwnershipAcquired;
}

static void releaseBridgeOwnership(void) {
    if (ownerLockFd < 0) return;
    flock(ownerLockFd, LOCK_UN);
    close(ownerLockFd);
    ownerLockFd = -1;
}

