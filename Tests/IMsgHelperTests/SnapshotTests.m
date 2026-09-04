#import <Foundation/Foundation.h>
#import <pwd.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>

// Bind the real path wrappers to an isolated home without touching Messages storage.
static const char *fixtureHome;
static struct passwd *fixtureGetpwuid(uid_t uid) {
    static struct passwd entry;
    entry.pw_dir = (char *)fixtureHome;
    entry.pw_uid = uid;
    return &entry;
}
static int readMode;
static int mutationFD = -1;
static ssize_t fixtureRead(int fd, void *buffer, size_t size) {
    int mode = readMode;
    readMode = 0;
    if (mode == 1 || mode == 2) {
        errno = mode == 1 ? EINTR : EIO;
        return -1;
    }
    ssize_t result = read(fd, buffer, size);
    if (mode >= 3) {
        struct stat info;
        NSCAssert(fstat(mutationFD, &info) == 0, @"Inspect mutation fixture");
        if (mode == 3 || mode == 4) {
            NSCAssert(ftruncate(mutationFD, mode == 3 ? 1 : info.st_size + 1) == 0,
                      @"Resize mutation fixture");
        } else {
            NSCAssert(pwrite(mutationFD, "x", 1, 0) == 1, @"Rewrite mutation fixture");
            struct timespec times[2] = {info.st_atimespec, info.st_mtimespec};
            times[1].tv_sec++;
            NSCAssert(futimens(mutationFD, times) == 0, @"Change fixture timestamp deterministically");
        }
    }
    return result;
}
#define getpwuid fixtureGetpwuid
#define read fixtureRead
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef read
#undef getpwuid

static NSUInteger failures;
static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static void checkRejected(NSString *path) {
    NSString *error = nil;
    check(readStickerSnapshot(path, &error) == nil && error.length,
          [@"Sticker must reject " stringByAppendingString:path.lastPathComponent]);
    error = nil;
    check(readRichLinkPreviewData(path, 3, &error) == nil && error.length,
          [@"Rich link must reject " stringByAppendingString:path.lastPathComponent]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3) {
            fixtureHome = argv[2];
            alarm(3);
            NSString *path = [trustedStickerRoot() stringByAppendingPathComponent:@"fifo"];
            NSString *error = nil;
            NSData *data = strcmp(argv[1], "sticker") == 0
                ? readStickerSnapshot(path, &error) : readRichLinkPreviewData(path, 3, &error);
            return data == nil && error.length ? 0 : 1;
        }

        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        fixtureHome = home.fileSystemRepresentation;
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *root = trustedStickerRoot();
        NSError *error = nil;
        check([files createDirectoryAtPath:root withIntermediateDirectories:YES
                               attributes:@{NSFilePosixPermissions: @0700} error:&error],
              @"Create synthetic staging root");
        NSString *regular = [root stringByAppendingPathComponent:@"regular"];
        NSData *bytes = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
        check([bytes writeToFile:regular atomically:NO], @"Write fixture");
        check([readStickerSnapshot(regular, nil) isEqual:bytes], @"Sticker bytes must match");
        check([readRichLinkPreviewData(regular, 3, nil) isEqual:bytes], @"Rich-link bytes must match");
        check(readRichLinkPreviewData(regular, 2, nil) == nil, @"Reject descriptor size mismatch");
        check(readRichLinkPreviewData(regular, 0, nil) == nil, @"Reject zero descriptor size");
        check([snapshotSHA256(bytes) isEqualToString:
               @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"],
              @"SHA-256 must match the known abc vector");

        int directoryFD = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY);
        check(directoryFD >= 0, @"Open borrowed directory fixture");
        check([readSnapshotAt(directoryFD, @"regular", 3, @3, nil) isEqual:bytes],
              @"Accept the exact byte limit");
        check(readSnapshotAt(directoryFD, @"regular", 2, nil, nil) == nil,
              @"Reject files over the caller's byte limit");
        readMode = 1;
        check([readSnapshotAt(directoryFD, @"regular", 3, nil, nil) isEqual:bytes],
              @"Retry an interrupted read");
        readMode = 2;
        check(readSnapshotAt(directoryFD, @"regular", 3, nil, nil) == nil, @"Report read errors");
        NSString *mutable = [root stringByAppendingPathComponent:@"mutable"];
        NSData *large = [NSMutableData dataWithLength:128 * 1024];
        for (int mode = 3; mode <= 5; mode++) {
            check([large writeToFile:mutable atomically:NO], @"Write mutable fixture");
            mutationFD = open(mutable.fileSystemRepresentation, O_WRONLY);
            check(mutationFD >= 0, @"Open mutation fixture");
            readMode = mode;
            check(readSnapshotAt(directoryFD, @"mutable", large.length, nil, nil) == nil,
                  @"Reject shrink, growth, and same-size mutation during reads");
            if (mutationFD >= 0) close(mutationFD);
            mutationFD = -1;
        }
        check(fcntl(directoryFD, F_GETFD) >= 0, @"The reader must preserve its borrowed directory FD");
        if (directoryFD >= 0) close(directoryFD);

        NSString *empty = [root stringByAppendingPathComponent:@"empty"];
        check([[NSData data] writeToFile:empty atomically:NO], @"Write empty fixture");
        checkRejected(empty);
        checkRejected(root);
        checkRejected([root stringByAppendingPathComponent:@"missing"]);

        NSString *symlinkPath = [root stringByAppendingPathComponent:@"symlink"];
        check(symlink(regular.fileSystemRepresentation, symlinkPath.fileSystemRepresentation) == 0,
              @"Create symlink fixture");
        checkRejected(symlinkPath);
        NSString *hardlinkPath = [root stringByAppendingPathComponent:@"hardlink"];
        check(link(regular.fileSystemRepresentation, hardlinkPath.fileSystemRepresentation) == 0,
              @"Create hard-link fixture");
        checkRejected(hardlinkPath);
        checkRejected(regular);
        check(unlink(hardlinkPath.fileSystemRepresentation) == 0, @"Remove extra link");

        NSString *oversize = [root stringByAppendingPathComponent:@"oversize"];
        int fd = open(oversize.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        check(fd >= 0 && ftruncate(fd, kMaxStickerBytes + 1) == 0, @"Create sparse oversized fixture");
        if (fd >= 0) close(fd);
        checkRejected(oversize);

        NSString *fifo = [root stringByAppendingPathComponent:@"fifo"];
        check(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, @"Create FIFO fixture");
        for (NSString *kind in @[@"sticker", @"rich-link"]) {
            NSTask *child = [NSTask new];
            child.executableURL = [NSURL fileURLWithPath:@(argv[0])];
            child.arguments = @[kind, home];
            if ([child launchAndReturnError:&error]) {
                [child waitUntilExit];
                check(child.terminationReason == NSTaskTerminationReasonExit && child.terminationStatus == 0,
                      [kind stringByAppendingString:@" must reject a FIFO before blocking"]);
            } else {
                check(NO, @"Launch bounded FIFO proof");
            }
        }
        check([files removeItemAtPath:home error:&error], @"Remove synthetic fixture");
        fprintf(stdout, "Bridge snapshot tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
