#pragma mark - Send Handlers (v2)

static NSString *richLinkActualUserHomeDirectory(void) {
    struct passwd *entry = getpwuid(getuid());
    if (!entry || !entry->pw_dir) return nil;
    return [NSString stringWithUTF8String:entry->pw_dir];
}

static NSString *trustedRichLinkStagingRoot(void) {
    return [[richLinkActualUserHomeDirectory()
        stringByAppendingPathComponent:@"Library/Messages/Attachments/imsg"]
        stringByStandardizingPath];
}

static BOOL richLinkPathIsTrusted(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) return NO;
    NSString *root = trustedRichLinkStagingRoot();
    NSString *candidate = path.stringByStandardizingPath;
    return root.length && [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static int openRichLinkDirectorySecurely(NSString *directoryPath) {
    NSString *root = trustedRichLinkStagingRoot();
    NSString *candidate = directoryPath.stringByStandardizingPath;
    if (!root.length || !candidate.length) return -1;
    BOOL isRoot = [candidate isEqualToString:root];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    if (!isRoot && ![candidate hasPrefix:rootPrefix]) return -1;

    int directoryFD = open(root.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
    if (directoryFD < 0) return -1;
    struct stat rootStat = {0};
    if (fstat(directoryFD, &rootStat) != 0 || !S_ISDIR(rootStat.st_mode) ||
        rootStat.st_uid != getuid() || (rootStat.st_mode & S_IWOTH) != 0) {
        close(directoryFD);
        return -1;
    }
    if (isRoot) return directoryFD;

    NSString *relative = [candidate substringFromIndex:rootPrefix.length];
    NSArray<NSString *> *components = relative.pathComponents;
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        int nextFD = openat(directoryFD, component.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
        close(directoryFD);
        if (nextFD < 0) return -1;
        directoryFD = nextFD;
    }
    return directoryFD;
}

static NSString *snapshotSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL richLinkIntegerNumber(NSNumber *number) {
    if (![number isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
    return !CFNumberIsFloatType((__bridge CFNumberRef)number);
}

// The caller owns the directory; this reader owns only the leaf descriptor.
static NSData *readSnapshotAt(int directoryFD, NSString *filename,
                              unsigned long long maximumBytes, NSNumber *expectedBytes,
                              NSString **outErr) {
    // O_NONBLOCK must precede fstat: opening a FIFO otherwise blocks Messages itself.
    int fd = openat(directoryFD, filename.fileSystemRepresentation,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        if (outErr) *outErr = @"Could not securely open image snapshot";
        return nil;
    }
    @try {
        struct stat before = {0};
        if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_nlink != 1) {
            if (outErr) *outErr = @"Image snapshot must be a single-link regular file";
            return nil;
        }
        if (before.st_size <= 0 || (unsigned long long)before.st_size > maximumBytes) {
            if (outErr) *outErr = [NSString stringWithFormat:
                @"Image snapshot must be between 1 byte and %llu bytes", maximumBytes];
            return nil;
        }
        if (expectedBytes && (unsigned long long)before.st_size != expectedBytes.unsignedLongLongValue) {
            if (outErr) *outErr = @"Image snapshot size does not match its descriptor";
            return nil;
        }
        NSUInteger size = (NSUInteger)before.st_size;
        NSMutableData *data = [NSMutableData dataWithCapacity:size];
        unsigned char buffer[64 * 1024];
        while (data.length < size) {
            ssize_t count = read(fd, buffer, MIN(sizeof(buffer), size - data.length));
            if (count == 0) break;
            if (count < 0) {
                if (errno == EINTR) continue;
                if (outErr) *outErr = @"Could not read image snapshot";
                return nil;
            }
            [data appendBytes:buffer length:(NSUInteger)count];
        }
        struct stat after = {0};
        BOOL changed = fstat(fd, &after) != 0
            || after.st_dev != before.st_dev
            || after.st_ino != before.st_ino
            || after.st_size != before.st_size
            || after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec
            || after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec
            || after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
            || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec;
        if (changed || data.length != size) {
            if (outErr) *outErr = @"Image snapshot changed while being read";
            return nil;
        }
        return data;
    } @finally {
        close(fd);
    }
}

static NSData *readRichLinkPreviewData(NSString *path,
                                       unsigned long long expectedSize,
                                       NSString **outErr) {
    if (!richLinkPathIsTrusted(path)) {
        if (outErr) *outErr = @"Rich-link image path is outside the secure staging directory";
        return nil;
    }
    int directoryFD = openRichLinkDirectorySecurely(path.stringByDeletingLastPathComponent);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open rich-link image directory";
        return nil;
    }
    NSData *data = readSnapshotAt(directoryFD, path.lastPathComponent,
                                 2ULL * 1024ULL * 1024ULL, @(expectedSize), outErr);
    close(directoryFD);
    return data;
}

static NSString *writeRichLinkPreviewSnapshot(NSData *data,
                                              NSString *contentHash,
                                              NSString **outErr) {
    NSString *root = trustedRichLinkStagingRoot();
    int rootFD = openRichLinkDirectorySecurely(root);
    if (rootFD < 0) {
        if (outErr) *outErr = @"Could not securely open rich-link staging root";
        return nil;
    }
    if (mkdirat(rootFD, "rich-links", 0700) != 0 && errno != EEXIST) {
        close(rootFD);
        if (outErr) *outErr = @"Could not create private rich-link directory";
        return nil;
    }
    int previewsFD = openat(rootFD, "rich-links",
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    close(rootFD);
    if (previewsFD < 0) {
        if (outErr) *outErr = @"Could not open private rich-link directory";
        return nil;
    }
    NSString *directoryName = NSUUID.UUID.UUIDString;
    if (mkdirat(previewsFD, directoryName.fileSystemRepresentation, 0700) != 0) {
        close(previewsFD);
        if (outErr) *outErr = @"Could not create private rich-link snapshot directory";
        return nil;
    }
    int directoryFD = openat(previewsFD, directoryName.fileSystemRepresentation,
                             O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (directoryFD < 0) {
        unlinkat(previewsFD, directoryName.fileSystemRepresentation, AT_REMOVEDIR);
        close(previewsFD);
        if (outErr) *outErr = @"Could not open private rich-link snapshot directory";
        return nil;
    }
    NSString *filename = [contentHash stringByAppendingString:@".pluginPayloadAttachment"];
    int fd = openat(directoryFD, filename.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0;
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (!ok) {
        unlinkat(directoryFD, filename.fileSystemRepresentation, 0);
        close(directoryFD);
        unlinkat(previewsFD, directoryName.fileSystemRepresentation, AT_REMOVEDIR);
        close(previewsFD);
        if (outErr) *outErr = @"Could not write private rich-link snapshot";
        return nil;
    }
    close(directoryFD);
    close(previewsFD);
    return [[[root stringByAppendingPathComponent:@"rich-links"]
        stringByAppendingPathComponent:directoryName]
        stringByAppendingPathComponent:filename];
}

static void removeRichLinkPreviewSnapshot(NSString *path) {
    NSString *root = [[trustedRichLinkStagingRoot()
        stringByAppendingPathComponent:@"rich-links"] stringByStandardizingPath];
    NSString *candidate = path.stringByStandardizingPath;
    if (!root.length || ![candidate hasPrefix:[root stringByAppendingString:@"/"]]) return;
    NSString *directory = candidate.stringByDeletingLastPathComponent;
    int directoryFD = openRichLinkDirectorySecurely(directory);
    if (directoryFD >= 0) {
        unlinkat(directoryFD, candidate.lastPathComponent.fileSystemRepresentation, 0);
        close(directoryFD);
    }
    NSString *parent = directory.stringByDeletingLastPathComponent;
    int parentFD = openRichLinkDirectorySecurely(parent);
    if (parentFD >= 0) {
        unlinkat(parentFD, directory.lastPathComponent.fileSystemRepresentation, AT_REMOVEDIR);
        close(parentFD);
    }
}

static BOOL validateRichLinkPreviewImage(NSDictionary *image,
                                         NSURL **outFileURL,
                                         NSString **outMimeType,
                                         NSString **outErr) {
    if (!image) return YES;
    NSSet *allowedKeys = [NSSet setWithArray:@[
        @"filePath", @"mimeType", @"contentHash", @"byteCount",
        @"pixelWidth", @"pixelHeight"
    ]];
    for (id key in image) {
        if (![key isKindOfClass:[NSString class]] || ![allowedKeys containsObject:key]) {
            if (outErr) *outErr = @"Invalid rich-link image descriptor";
            return NO;
        }
    }
    NSString *filePath = [image[@"filePath"] isKindOfClass:[NSString class]]
        ? image[@"filePath"] : @"";
    NSString *mimeType = [image[@"mimeType"] isKindOfClass:[NSString class]]
        ? [image[@"mimeType"] lowercaseString] : @"";
    NSString *contentHash = [image[@"contentHash"] isKindOfClass:[NSString class]]
        ? [image[@"contentHash"] lowercaseString] : @"";
    NSNumber *byteCount = image[@"byteCount"];
    NSNumber *pixelWidth = image[@"pixelWidth"];
    NSNumber *pixelHeight = image[@"pixelHeight"];
    NSSet *allowedMIMETypes = [NSSet setWithArray:@[
        @"image/jpeg", @"image/png", @"image/webp"
    ]];
    NSInteger width = pixelWidth.integerValue;
    NSInteger height = pixelHeight.integerValue;
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    if (!filePath.length || ![filePath hasSuffix:@".pluginPayloadAttachment"] ||
        ![allowedMIMETypes containsObject:mimeType] || contentHash.length != 64 ||
        [contentHash rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
        !richLinkIntegerNumber(byteCount) || !richLinkIntegerNumber(pixelWidth) ||
        !richLinkIntegerNumber(pixelHeight) ||
        byteCount.longLongValue <= 0 || byteCount.longLongValue > 2 * 1024 * 1024 ||
        width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        width > (16 * 1024 * 1024) / height) {
        if (outErr) *outErr = @"Rich-link image metadata exceeds safe limits";
        return NO;
    }

    NSData *data = readRichLinkPreviewData(filePath.stringByStandardizingPath,
        byteCount.unsignedLongLongValue, outErr);
    if (!data) return NO;
    if (![[snapshotSHA256(data) lowercaseString] isEqualToString:contentHash]) {
        if (outErr) *outErr = @"Rich-link image hash does not match its descriptor";
        return NO;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source || CGImageSourceGetCount(source) != 1) {
        if (source) CFRelease(source);
        if (outErr) *outErr = @"Rich-link image must contain exactly one decodable frame";
        return NO;
    }
    NSString *uti = (__bridge NSString *)CGImageSourceGetType(source);
    BOOL typeMatches = ([mimeType isEqualToString:@"image/png"] && [uti isEqualToString:@"public.png"])
        || ([mimeType isEqualToString:@"image/jpeg"] && [uti isEqualToString:@"public.jpeg"])
        || ([mimeType isEqualToString:@"image/webp"] &&
            ([uti isEqualToString:@"org.webmproject.webp"] || [uti isEqualToString:@"public.webp"]));
    CFDictionaryRef rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    NSDictionary *properties = CFBridgingRelease(rawProperties);
    NSInteger actualWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger actualHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] integerValue];
    if (!typeMatches || !properties || actualWidth != width || actualHeight != height) {
        CFRelease(source);
        if (outErr) *outErr = @"Rich-link image metadata does not match its descriptor";
        return NO;
    }
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!decoded) {
        if (outErr) *outErr = @"Rich-link image could not be decoded safely";
        return NO;
    }
    CGImageRelease(decoded);
    NSString *snapshotPath = writeRichLinkPreviewSnapshot(data, contentHash, outErr);
    if (!snapshotPath.length) return NO;
    if (outFileURL) *outFileURL = [NSURL fileURLWithPath:snapshotPath];
    if (outMimeType) *outMimeType = mimeType;
    return YES;
}

/// Implementation core for `send-message`. Builds an IMMessage with optional
/// effect/subject/reply and dispatches via `[chat sendMessage:]`. ddScan on
/// macOS 13+ defers the send by 100ms.
