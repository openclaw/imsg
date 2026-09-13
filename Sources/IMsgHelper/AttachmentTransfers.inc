static NSAttributedString *annotateBodyForRichLink(NSAttributedString *body,
                                                   NSString *urlString) {
    if (!body.length || !urlString.length) return body;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return body;
    NSMutableAttributedString *annotated = [body mutableCopy];
    NSString *plain = annotated.string ?: @"";
    NSRange range = [plain rangeOfString:urlString];
    if (range.location == NSNotFound || range.length == 0 ||
        range.location != 0 || range.length != annotated.length) return nil;
    [annotated addAttribute:@"__kIMLinkAttributeName" value:url range:range];
    [annotated addAttribute:@"__kIMLinkIsRichLinkAttributeName" value:@YES range:range];
    [annotated addAttribute:NSLinkAttributeName value:url range:range];
    return annotated;
}

/// Register an outgoing file transfer with IMFileTransferCenter so that
/// Messages.app/imagent persists the attachment row and links it back to the
/// outbound message. Mirrors BlueBubblesHelper's `prepareFileTransferForAttachment`:
///   1. Allocate a guid via `guidForNewOutgoingTransferWithLocalURL:`.
///   2. Resolve the resulting `IMFileTransfer` via `transferForGUID:`.
///   3. Stage the source file in the IMD-managed attachments tree.
///   4. `retargetTransfer:toPath:` + `setLocalURL:` to point the transfer at
///      the staged copy.
/// The caller registers the prepared transfer only after message construction
/// succeeds, avoiding daemon-visible orphan transfers on builder failures.
/// On failure returns `nil`; the caller emits the error.
static BOOL retargetPreparedTransfer(id ftc, IMFileTransfer *transfer,
                                     NSString *transferGuid, NSString *path) {
    if (!path.length) return NO;
    // Updating only `localURL` is not enough: IMFileTransferCenter keeps its
    // own guid -> path map, and imagent reads that map when daemon registration
    // happens.
    BOOL retargetedCenter = [ftc respondsToSelector:@selector(retargetTransfer:toPath:)];
    if (retargetedCenter) {
        NSMethodSignature *rsig = [ftc methodSignatureForSelector:
            @selector(retargetTransfer:toPath:)];
        NSInvocation *rinv = [NSInvocation invocationWithMethodSignature:rsig];
        [rinv setSelector:@selector(retargetTransfer:toPath:)];
        [rinv setTarget:ftc];
        __unsafe_unretained NSString *g = transferGuid;
        __unsafe_unretained NSString *p = path;
        [rinv setArgument:&g atIndex:2];
        [rinv setArgument:&p atIndex:3];
        [rinv invoke];
    }
    if ([transfer respondsToSelector:@selector(setLocalURL:)]) {
        [transfer performSelector:@selector(setLocalURL:)
                       withObject:[NSURL fileURLWithPath:path]];
    }
    return retargetedCenter;
}

static BOOL pathsReferToSameFile(NSString *lhs, NSString *rhs) {
    if (!lhs.length || !rhs.length) return NO;
    if ([lhs.stringByStandardizingPath isEqualToString:rhs.stringByStandardizingPath]) {
        return YES;
    }
    struct stat leftInfo = {0};
    struct stat rightInfo = {0};
    return stat(lhs.fileSystemRepresentation, &leftInfo) == 0
        && stat(rhs.fileSystemRepresentation, &rightInfo) == 0
        && leftInfo.st_dev == rightInfo.st_dev
        && leftInfo.st_ino == rightInfo.st_ino;
}

static BOOL configurePreviewPayloadTransfer(IMFileTransfer *transfer,
                                            NSString *mimeType,
                                            NSString *filename) {
    if (!transfer || !mimeType.length || !filename.length ||
        ![transfer respondsToSelector:@selector(setHideAttachment:)] ||
        ![transfer respondsToSelector:@selector(setMimeType:)] ||
        ![transfer respondsToSelector:@selector(setTransferredFilename:)]) {
        return NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transfer,
                                            @selector(setHideAttachment:),
                                            YES);
    [transfer performSelector:@selector(setMimeType:) withObject:mimeType];
    [transfer performSelector:@selector(setTransferredFilename:) withObject:filename];
    return YES;
}

static IMFileTransfer *prepareOutgoingTransfer(NSURL *originalURL, NSString *filename,
                                               NSString *chatGuid,
                                               IMsgOutgoingTransferKind transferKind,
                                               NSDictionary *transferMetadata,
                                               NSString **outActivePath,
                                               NSString **outErr) {
    if (outActivePath) *outActivePath = originalURL.path;
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    if (!ftcClass) {
        if (outErr) *outErr = @"IMFileTransferCenter not available";
        return nil;
    }
    id ftc = [ftcClass performSelector:@selector(sharedInstance)];
    if (!ftc) {
        if (outErr) *outErr = @"FileTransferCenter unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(guidForNewOutgoingTransferWithLocalURL:)]) {
        if (outErr) *outErr = @"guidForNewOutgoingTransferWithLocalURL: unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(transferForGUID:)]) {
        if (outErr) *outErr = @"transferForGUID: unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(registerTransferWithDaemon:)]) {
        if (outErr) *outErr = @"registerTransferWithDaemon: unavailable";
        return nil;
    }

    id rawGuid = [ftc performSelector:@selector(guidForNewOutgoingTransferWithLocalURL:)
                           withObject:originalURL];
    if (![rawGuid isKindOfClass:[NSString class]] || ![(NSString *)rawGuid length]) {
        if (outErr) *outErr = @"Could not allocate transfer guid";
        return nil;
    }
    NSString *transferGuid = (NSString *)rawGuid;

    IMFileTransfer *transfer =
        [ftc performSelector:@selector(transferForGUID:) withObject:transferGuid];
    if (!transfer) {
        if (outErr) *outErr = @"Could not resolve IMFileTransfer for guid";
        return nil;
    }

    // Try to copy the source file into the IMD-managed attachments tree and
    // retarget the transfer. macOS 26 returns nil here if `chatGUID` is nil;
    // passing the real chat GUID is what gives IMD enough context to choose the
    // per-chat attachment-store path that Messages/imagent will accept.
    Class pacClass = NSClassFromString(@"IMDPersistentAttachmentController");
    if (pacClass && transferKind != IMsgOutgoingTransferKindRichLinkPreview) {
        id pac = [pacClass performSelector:@selector(sharedInstance)];
        SEL pathSel = @selector(_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:);
        if (pac && [pac respondsToSelector:pathSel]) {
            NSMethodSignature *sig = [pac methodSignatureForSelector:pathSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:pathSel];
            [inv setTarget:pac];
            __unsafe_unretained IMFileTransfer *xfer = transfer;
            __unsafe_unretained NSString *fn = filename ?: [originalURL lastPathComponent];
            __unsafe_unretained NSString *cg = chatGuid;
            BOOL hi = YES;
            BOOL ext = YES;
            [inv setArgument:&xfer atIndex:2];
            [inv setArgument:&fn atIndex:3];
            [inv setArgument:&hi atIndex:4];
            [inv setArgument:&cg atIndex:5];
            [inv setArgument:&ext atIndex:6];
            [inv retainArguments];
            [inv invoke];
            __unsafe_unretained NSString *raw = nil;
            [inv getReturnValue:&raw];
            // Take a strong reference immediately — invocation returns an
            // unretained pointer that ARC may release before the next use.
            NSString *persistentPath = raw;
            debugLog(@"prepareOutgoingTransfer: persistentPath=%@ filename=%@",
                     persistentPath ?: @"(nil)", fn);

            NSError *legacyErr = nil;
            BOOL legacyStaged = NO;
            BOOL persistentMatchesSource = NO;
            BOOL canRetargetSticker = transferKind != IMsgOutgoingTransferKindSticker
                || ([ftc respondsToSelector:@selector(retargetTransfer:toPath:)]
                    && pathIsWithinRoot(persistentPath, trustedMessagesAttachmentsRoot()));
            if (persistentPath.length && canRetargetSticker) {
                NSURL *persistentURL = [NSURL fileURLWithPath:persistentPath];
                NSURL *parent = [persistentURL URLByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtURL:parent
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:&legacyErr];
                if (!legacyErr) {
                    persistentMatchesSource =
                        pathsReferToSameFile(originalURL.path, persistentPath);
                    if (persistentMatchesSource) {
                        legacyStaged = YES;
                    } else {
                        NSURL *temporaryURL = [parent URLByAppendingPathComponent:
                            [NSString stringWithFormat:@".imsg-%@", NSUUID.UUID.UUIDString]];
                        [[NSFileManager defaultManager] copyItemAtURL:originalURL
                                                                toURL:temporaryURL
                                                                error:&legacyErr];
                        if (!legacyErr
                            && rename(temporaryURL.path.fileSystemRepresentation,
                                      persistentPath.fileSystemRepresentation) != 0) {
                            legacyErr = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                           code:errno
                                                       userInfo:nil];
                        }
                        if (legacyErr) {
                            [[NSFileManager defaultManager]
                                removeItemAtURL:temporaryURL error:NULL];
                        }
                    }
                    if (!legacyErr) {
                        BOOL retargeted = retargetPreparedTransfer(
                            ftc, transfer, transferGuid, persistentPath);
                        if (transferKind != IMsgOutgoingTransferKindSticker || retargeted) {
                            if (outActivePath) *outActivePath = persistentPath;
                            legacyStaged = YES;
                        }
                    }
                }
            }
            if (!legacyStaged) {
                // IMDPersistence on macOS 26 / Tahoe returns either nil (when
                // chatGUID is nil, per BlueBubbles' reference implementation)
                // or an iOS-style /var/mobile/... path (when chatGUID is
                // non-nil) that Messages.app can't actually write to. The
                // _alternative_ fallback that some IMDPersistence builds
                // expose, saveAttachmentsForTransfer:chatGUID:storeAtExternalLocation:completion:,
                // returns a path inside the Messages.app sandbox container
                // that imagent can't read from for outgoing sends (the row
                // lands in chat.db but error=25, is_sent=0).
                //
                // The transfer was created via guidForNewOutgoingTransferWithLocalURL:
                // with the source already living under
                // ~/Library/Messages/Attachments/imsg/<UUID>/<file> (Swift's
                // MessageSender.stageAttachmentForMessagesApp puts it there
                // before we get here). That path is in the user-visible
                // Attachments tree, which imagent reads happily — BlueBubbles
                // takes the same approach when its persistentPath comes back
                // nil. So when the legacy retarget can't run, leave the
                // transfer pointing at its original localURL and let
                // registerTransferWithDaemon: pick it up directly.
                if (legacyErr) {
                    debugLog(@"prepareOutgoingTransfer: legacy path %@ unusable (%@); "
                             @"keeping original localURL=%@ for registerTransferWithDaemon",
                             persistentPath ?: @"(nil)", legacyErr.localizedDescription,
                             originalURL.path);
                } else {
                    debugLog(@"prepareOutgoingTransfer: no persistent path; keeping "
                             @"original localURL=%@", originalURL.path);
                }
            }
        }
    }

    if (outActivePath) {
        NSString *observedPath = nil;
        if ([transfer respondsToSelector:@selector(localURL)]) {
            id value = [transfer performSelector:@selector(localURL)];
            if ([value isKindOfClass:[NSURL class]]) observedPath = [value path];
        }
        if (!observedPath.length && [transfer respondsToSelector:@selector(localPath)]) {
            id value = [transfer performSelector:@selector(localPath)];
            if ([value isKindOfClass:[NSString class]]) observedPath = value;
        }
        if (observedPath.length
            && !pathsReferToSameFile(observedPath, originalURL.path)
            && [[NSFileManager defaultManager] fileExistsAtPath:observedPath]) {
            *outActivePath = observedPath;
        }
        NSString *activePath = *outActivePath;
        if (activePath.length
            && !pathsReferToSameFile(activePath, originalURL.path)
            && [[NSFileManager defaultManager] fileExistsAtPath:activePath]
            && !removeStickerFileSecurely(originalURL.path)) {
            if (outErr) *outErr = @"Could not remove redundant sticker snapshot";
            return nil;
        }
    }

    if (transferKind == IMsgOutgoingTransferKindRichLinkPreview) {
        NSString *mimeType = transferMetadata[@"mimeType"];
        if (!configurePreviewPayloadTransfer(transfer, mimeType, filename)) {
            if (outErr) *outErr = @"Hidden preview transfer selectors unavailable";
            return nil;
        }
    }

    if (transferKind == IMsgOutgoingTransferKindSticker) {
        NSString *stickerErr = nil;
        NSString *accessibilityLabel = transferMetadata[@"accessibilityLabel"];
        if (!markTransferAsSticker(transfer, accessibilityLabel,
                                   transferMetadata, &stickerErr)) {
            if (outErr) *outErr = stickerErr ?: @"Could not mark transfer as sticker";
            return nil;
        }
    }

    return transfer;
}

static IMFileTransfer *prepareUnregisteredOutgoingTransfer(
    NSURL *originalURL, NSString *filename, NSString *chatGuid,
    BOOL hideAttachment, NSString *mimeType, NSString **outErr) {
    IMsgOutgoingTransferKind kind = hideAttachment
        ? IMsgOutgoingTransferKindRichLinkPreview
        : IMsgOutgoingTransferKindAttachment;
    NSDictionary *metadata = mimeType.length ? @{ @"mimeType": mimeType } : nil;
    return prepareOutgoingTransfer(originalURL, filename, chatGuid, kind,
                                   metadata, NULL, outErr);
}

static BOOL registerPreparedTransfer(IMFileTransfer *transfer, NSString **outErr) {
    NSString *transferGuid = [transfer guid];
    if (!transferGuid.length) {
        if (outErr) *outErr = @"Prepared transfer has no guid";
        return NO;
    }
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    id center = centerClass ? [centerClass performSelector:@selector(sharedInstance)] : nil;
    if (!center || ![center respondsToSelector:@selector(registerTransferWithDaemon:)]) {
        if (outErr) *outErr = @"registerTransferWithDaemon: unavailable";
        return NO;
    }
    [center performSelector:@selector(registerTransferWithDaemon:) withObject:transferGuid];
    return YES;
}

/// `send-attachment`: registers the file via IMFileTransferCenter and sends a
/// message whose attributedBody carries the OBJ placeholder tagged with the
/// transfer guid (Messages requires this attribute or the attachment row is
/// never linked to the outgoing message).
