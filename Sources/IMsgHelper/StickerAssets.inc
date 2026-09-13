static const unsigned long long kMaxStickerBytes = 500ULL * 1024ULL;
static const NSUInteger kMaxStickerDimension = 618;
static const NSUInteger kMaxStickerFrames = 100;
static const unsigned long long kMaxStickerDecodedPixels = 25000000ULL;
static NSString * const kDefaultStickerParentPreviewWidth = @"163.73095703";

static NSString *actualUserHomeDirectory(void) {
    struct passwd *entry = getpwuid(getuid());
    if (!entry || !entry->pw_dir) return nil;
    return [NSString stringWithUTF8String:entry->pw_dir];
}

static NSString *trustedMessagesAttachmentsRoot(void) {
    return [actualUserHomeDirectory()
        stringByAppendingPathComponent:@"Library/Messages/Attachments"];
}

static NSString *trustedStickerRoot(void) {
    return [trustedMessagesAttachmentsRoot()
        stringByAppendingPathComponent:@"imsg/stickers"];
}

static BOOL pathIsWithinRoot(NSString *path, NSString *root) {
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) return NO;
    NSString *candidate = [path stringByStandardizingPath];
    NSString *standardRoot = [root stringByStandardizingPath];
    return standardRoot.length
        && [candidate hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static BOOL stickerPathIsTrusted(NSString *path) {
    return pathIsWithinRoot(path, trustedStickerRoot());
}

static int openUserOwnedDirectorySecurely(NSString *directoryPath,
                                          NSString *requiredRoot) {
    NSString *root = [requiredRoot stringByStandardizingPath];
    NSString *directory = [directoryPath stringByStandardizingPath];
    if (!root.length || !directory.length) return -1;
    if (![directory isEqualToString:root]
        && ![directory hasPrefix:[root stringByAppendingString:@"/"]]) {
        return -1;
    }

    int directoryFD = open(root.fileSystemRepresentation,
                           O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (directoryFD < 0) return -1;
    struct stat rootInfo = {0};
    if (fstat(directoryFD, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode)
        || rootInfo.st_uid != getuid() || (rootInfo.st_mode & S_IWOTH)) {
        close(directoryFD);
        return -1;
    }
    if ([directory isEqualToString:root]) return directoryFD;

    NSString *relative = [directory substringFromIndex:root.length + 1];
    NSArray<NSString *> *components = relative.pathComponents;
    for (NSString *component in components) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]
            || [component isEqualToString:@"/"] || component.length == 0) {
            close(directoryFD);
            return -1;
        }
        int nextFD = openat(directoryFD, component.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
        close(directoryFD);
        if (nextFD < 0) return -1;
        struct stat componentInfo = {0};
        if (fstat(nextFD, &componentInfo) != 0 || !S_ISDIR(componentInfo.st_mode)
            || componentInfo.st_uid != getuid() || (componentInfo.st_mode & S_IWOTH)) {
            close(nextFD);
            return -1;
        }
        directoryFD = nextFD;
    }
    return directoryFD;
}

static int openStickerDirectorySecurely(NSString *directoryPath) {
    return openUserOwnedDirectorySecurely(directoryPath, trustedStickerRoot());
}

static int openStickerTransferDirectorySecurely(NSString *directoryPath) {
    return openUserOwnedDirectorySecurely(
        directoryPath, trustedMessagesAttachmentsRoot());
}

static NSData *readStickerSnapshot(NSString *path, NSString **outErr) {
    int directoryFD = openStickerDirectorySecurely(path.stringByDeletingLastPathComponent);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open sticker directory";
        return nil;
    }
    NSData *data = readSnapshotAt(directoryFD, path.lastPathComponent, kMaxStickerBytes, nil, outErr);
    close(directoryFD);
    return data;
}

static NSString *stickerMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL stickerContainerIsComplete(NSData *data, NSString *uti) {
    const unsigned char *bytes = data.bytes;
    if ([uti isEqualToString:@"public.png"]) {
        static const unsigned char iend[] = {
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        };
        return data.length >= sizeof(iend)
            && memcmp(bytes + data.length - sizeof(iend), iend, sizeof(iend)) == 0;
    }
    if ([uti isEqualToString:@"com.compuserve.gif"]) {
        return data.length > 0 && bytes[data.length - 1] == 0x3b;
    }
    if ([uti isEqualToString:@"public.jpeg"]) {
        return data.length >= 2
            && bytes[data.length - 2] == 0xff
            && bytes[data.length - 1] == 0xd9;
    }
    return NO;
}

static NSDictionary *stickerAssetMetadata(NSString *path, NSString **outErr) {
    if (!stickerPathIsTrusted(path) || pathHasSymlinkComponent(path)) {
        if (outErr) *outErr = @"Sticker must use imsg's trusted staging directory";
        return nil;
    }
    NSData *data = readStickerSnapshot(path, outErr);
    if (!data) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        if (outErr) *outErr = @"Sticker file is not a decodable image";
        return nil;
    }
    NSUInteger frameCount = CGImageSourceGetCount(source);
    if (frameCount == 0 || frameCount > kMaxStickerFrames) {
        if (source) CFRelease(source);
        if (outErr) {
            *outErr = [NSString stringWithFormat:
                @"Sticker must contain 1...%lu frames", (unsigned long)kMaxStickerFrames];
        }
        return nil;
    }
    NSString *uti = (__bridge NSString *)CGImageSourceGetType(source);
    NSSet *supportedTypes = [NSSet setWithObjects:
        @"public.png", @"com.compuserve.gif", @"public.jpeg", nil];
    if (![supportedTypes containsObject:uti]) {
        CFRelease(source);
        if (outErr) {
            *outErr = [NSString stringWithFormat:
                @"Unsupported sticker image format: %@", uti ?: @"unknown"];
        }
        return nil;
    }
    if (!stickerContainerIsComplete(data, uti)) {
        CFRelease(source);
        if (outErr) *outErr = @"Sticker image data is incomplete";
        return nil;
    }
    NSUInteger firstWidth = 0;
    NSUInteger firstHeight = 0;
    unsigned long long decodedPixels = 0;
    for (NSUInteger index = 0; index < frameCount; index++) {
        CFDictionaryRef rawProperties =
            CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
        if (!rawProperties) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker file contains invalid frame metadata";
            return nil;
        }
        NSDictionary *properties = CFBridgingRelease(rawProperties);
        NSUInteger width =
            [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        NSUInteger height =
            [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        if (width == 0 || height == 0 || width > kMaxStickerDimension
            || height > kMaxStickerDimension) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker image dimensions are invalid or too large";
            return nil;
        }
        if (index == 0) {
            firstWidth = width;
            firstHeight = height;
        }
        decodedPixels += (unsigned long long)width * (unsigned long long)height;
        if (decodedPixels > kMaxStickerDecodedPixels) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker animation contains too many decoded pixels";
            return nil;
        }
        CGImageRef frame = CGImageSourceCreateImageAtIndex(source, index, NULL);
        if (!frame) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker file contains an undecodable frame";
            return nil;
        }
        CGImageRelease(frame);
    }
    CFRelease(source);
    NSString *hash = snapshotSHA256(data);
    NSString *md5 = stickerMD5(data);
    NSString *extension = [uti isEqualToString:@"public.png"] ? @"png"
        : ([uti isEqualToString:@"public.jpeg"] ? @"jpg" : @"gif");
    return @{
        @"data": data,
        @"extension": extension,
        @"hash": hash,
        @"md5": md5,
        @"width": @(firstWidth),
        @"height": @(firstHeight),
        @"uti": uti,
    };
}

static NSString *writeStickerSnapshot(NSDictionary *metadata, NSString *sourcePath,
                                      NSString **outErr) {
    NSData *data = metadata[@"data"];
    NSString *hash = metadata[@"hash"];
    NSString *extension = metadata[@"extension"];
    if (!data.length || !hash.length || !extension.length) {
        if (outErr) *outErr = @"Missing validated sticker snapshot";
        return nil;
    }
    NSString *directory = [sourcePath stringByDeletingLastPathComponent];
    NSString *name = [NSString stringWithFormat:@"%@.%@", hash, extension];
    NSString *path = [directory stringByAppendingPathComponent:name];
    int directoryFD = openStickerDirectorySecurely(directory);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open sticker directory";
        return nil;
    }
    int fd = openat(directoryFD, name.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        close(directoryFD);
        if (outErr) *outErr = @"Could not create private sticker snapshot";
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    BOOL ok = YES;
    while (offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    struct stat descriptorInfo = {0};
    struct stat pathInfo = {0};
    if (ok && fstat(fd, &descriptorInfo) != 0) ok = NO;
    if (ok && (lstat(path.fileSystemRepresentation, &pathInfo) != 0
        || pathInfo.st_dev != descriptorInfo.st_dev
        || pathInfo.st_ino != descriptorInfo.st_ino
        || !S_ISREG(pathInfo.st_mode))) ok = NO;
    if (close(fd) != 0) ok = NO;
    if (!ok) {
        unlinkat(directoryFD, name.fileSystemRepresentation, 0);
        close(directoryFD);
        if (outErr) *outErr = @"Could not write private sticker snapshot";
        return nil;
    }
    close(directoryFD);
    return path;
}

static BOOL removeStickerFileSecurely(NSString *path) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryFD = openStickerDirectorySecurely(directory);
    if (directoryFD < 0) return NO;
    int result = unlinkat(
        directoryFD, path.lastPathComponent.fileSystemRepresentation, 0);
    int savedErrno = errno;
    close(directoryFD);
    return result == 0 || savedErrno == ENOENT;
}

static BOOL removeStickerTransferFileSecurely(NSString *path) {
    if (!pathIsWithinRoot(path, trustedMessagesAttachmentsRoot())) return NO;
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryFD = openStickerTransferDirectorySecurely(directory);
    if (directoryFD < 0) return NO;
    int result = unlinkat(
        directoryFD, path.lastPathComponent.fileSystemRepresentation, 0);
    int savedErrno = errno;
    close(directoryFD);
    return result == 0 || savedErrno == ENOENT;
}

static BOOL stickerMessageBelongsToChat(IMChat *chat, NSString *messageGuid) {
    SEL selector = NSSelectorFromString(@"hasStoredMessageWithGUID:");
    if (!chat || !messageGuid.length || ![chat respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(chat, selector, messageGuid);
}

static NSDictionary *stickerUserInfo(NSDictionary *metadata) {
    NSString *hash = metadata[@"hash"];
    NSString *md5 = metadata[@"md5"];
    NSString *filename = metadata[@"filename"];
    return @{
        @"pid": @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension",
        @"safi": @0,
        @"sai": @"0",
        // Apple uses MD5 for the sticker hash and the source basename for the
        // sticker GUID. Integrity still uses the out-of-band SHA-256 above.
        @"shash": md5,
        @"sid": filename,
        @"sli": @"0",
        @"spv": @0,
        // Native user-generated stickers include the target preview width in
        // this geometry tuple. Until a stable target-layout selector is known,
        // retain the proven centered default rather than misusing image width.
        @"spw": kDefaultStickerParentPreviewWidth,
        @"sro": @"0.00000000",
        @"ssa": @"1.00000000",
        @"stickerEffectType": @(-1),
        @"suri": [NSString stringWithFormat:@"sticker:///imsg/%@", hash],
        @"sxs": @"0.50000000",
        @"sys": @"0.50000000"
    };
}

static NSDictionary *stickerAttributionInfo(NSString *accessibilityLabel,
                                             NSDictionary *metadata) {
    NSString *label = [[accessibilityLabel componentsSeparatedByCharactersInSet:
        [NSCharacterSet controlCharacterSet]] componentsJoinedByString:@" "];
    label = [label stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!label.length) label = @"Sticker";
    if (label.length > 150) {
        NSRange safeRange = [label rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 150)];
        label = [label substringWithRange:safeRange];
    }
    return @{
        @"accessl": label,
        @"bundle-id": @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension",
        @"name": @"Stickers",
        @"pgensh": metadata[@"height"] ?: @0,
        @"pgensw": metadata[@"width"] ?: @0,
        @"pgenszc": @{
            @"gm": @NO,
            @"iaig": @NO,
            @"mpw": @"600.000000",
            @"mth": @"100.000000",
            @"mtw": @"100.000000",
            @"s": @"1.000000",
            @"st": @NO
        }
    };
}

static BOOL markTransferAsSticker(IMFileTransfer *transfer,
                                  NSString *accessibilityLabel,
                                  NSDictionary *metadata,
                                  NSString **outErr) {
    if (!transfer) {
        if (outErr) *outErr = @"Missing transfer";
        return NO;
    }
    if (![transfer respondsToSelector:@selector(setIsSticker:)]
        || ![transfer respondsToSelector:@selector(setStickerUserInfo:)]
        || ![transfer respondsToSelector:@selector(setAttributionInfo:)]) {
        if (outErr) *outErr = @"Required IMFileTransfer sticker selectors unavailable";
        return NO;
    }
    BOOL yes = YES;
    NSMethodSignature *sig = [transfer methodSignatureForSelector:@selector(setIsSticker:)];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:@selector(setIsSticker:)];
    [inv setTarget:transfer];
    [inv setArgument:&yes atIndex:2];
    [inv invoke];
    NSDictionary *stickerInfo = stickerUserInfo(metadata);
    [transfer performSelector:@selector(setStickerUserInfo:) withObject:stickerInfo];
    [transfer performSelector:@selector(setAttributionInfo:)
                   withObject:stickerAttributionInfo(accessibilityLabel, metadata)];
    setIntegerProperty(transfer, @selector(setPreviewGenerationState:), 1);
    setIntegerProperty(transfer, @selector(setPreviewGenerationVersion:), 1);
    return YES;
}

