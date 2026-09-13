static NSString *threadOriginatorPartForChatItem(id parentItem) {
    if (!parentItem
        || ![parentItem respondsToSelector:@selector(messagePartRange)]) {
        return nil;
    }
    NSRange range = [(IMMessagePartChatItem *)parentItem messagePartRange];
    if (range.length == 0) return nil;

    NSInteger partIndex = 0;
    SEL indexSel = @selector(index);
    if ([parentItem respondsToSelector:indexSel]) {
        NSMethodSignature *sig = [parentItem methodSignatureForSelector:indexSel];
        if (sig && strcmp(sig.methodReturnType, @encode(NSInteger)) == 0) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:indexSel];
            [inv setTarget:parentItem];
            [inv invoke];
            [inv getReturnValue:&partIndex];
        }
    }

    return [NSString stringWithFormat:@"%ld:%lu:%lu",
                                      (long)partIndex,
                                      (unsigned long)range.location,
                                      (unsigned long)range.length];
}

static void applyThreadOriginatorGUIDHints(id object,
                                           NSString *threadOriginatorGUID,
                                           NSString *threadOriginatorPart) {
    if (!object) return;
    if (threadOriginatorGUID.length) {
        SEL sel = NSSelectorFromString(@"setThreadOriginatorGUID:");
        if ([object respondsToSelector:sel]) {
            [object performSelector:sel withObject:threadOriginatorGUID];
        }
    }
    if (threadOriginatorPart.length) {
        SEL sel = NSSelectorFromString(@"setThreadOriginatorPart:");
        if ([object respondsToSelector:sel]) {
            [object performSelector:sel withObject:threadOriginatorPart];
        }
    }
}

static unsigned long long flagsForMessagePayload(NSAttributedString *subject,
                                                 NSArray *fileTransferGuids,
                                                 BOOL isAudioMessage) {
    if (isAudioMessage) {
        return 0x300005ULL;
    }
    if (subject.length) {
        return 0x10000dULL;
    }
    if (fileTransferGuids.count > 0) {
        return 0x100005ULL;
    }
    return 0x100005ULL;
}

static unsigned long long flagsForAssociatedMessagePayload(NSAttributedString *subject,
                                                           NSArray *fileTransferGuids,
                                                           BOOL isAudioMessage) {
    if (fileTransferGuids.count == 0) {
        return 0x5ULL;
    }
    return flagsForMessagePayload(subject, fileTransferGuids, isAudioMessage);
}

/// Build an IMMessage suitable for `[chat sendMessage:]`. Handles plain text,
/// optional subject, optional effect (`com.apple.MobileSMS.expressivesend.*`),
/// optional reply target (`selectedMessageGuid`), and ddScan flag.
///
/// On macOS 26 `+initIMMessageWith…` returns a message whose underlying
/// IMMessageItem has empty `bodyData`, which imagent silently drops. Try the
/// IMMessageItem-first path first; fall back to the legacy initializer for
/// older OSes that don't expose the modern item-construction selectors.
static id buildIMMessage(NSAttributedString *body,
                         NSAttributedString *subject,
                         NSString *effectId,
                         NSString *threadIdentifier,
                         id threadOriginator,
                         NSString *associatedMessageGuid,
                         long long associatedMessageType,
                         NSRange associatedMessageRange,
                         NSDictionary *summaryInfo,
                         NSArray *fileTransferGuids,
                         BOOL isAudioMessage,
                         BOOL ddScan,
                         NSString *clientMessageGuid) {
    // Reactions take a different code path entirely (macOS 26 init below) —
    // the IMMessageItem-first construction can't carry associated-message
    // fields atomically, and post-init setters don't survive the wrap.
    //
    // Attachments also bypass IMMessageItem-first: BB's `initWithSender:…:
    // expressiveSendStyleID:` (further down) handles fileTransferGUIDs
    // natively, and going through IMMessageItem-first appears to leave the
    // attachment payload unfinalized even with the right flags.
    BOOL isReaction = associatedMessageGuid.length && associatedMessageType > 0;
    BOOL hasAttachment = fileTransferGuids.count > 0;
    if (!isReaction && !hasAttachment) {
        id viaItem = constructIMMessageViaItem(body, subject, effectId,
                                                threadIdentifier,
                                                threadOriginator,
                                                associatedMessageGuid,
                                                associatedMessageType,
                                                associatedMessageRange,
                                                summaryInfo,
                                                fileTransferGuids,
                                                isAudioMessage,
                                                clientMessageGuid);
        if (viaItem) return viaItem;
    }
    // Legacy fallback for older macOS that doesn't expose the
    // IMMessageItem 9-arg initializer or +messageFromIMMessageItem:.
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;

    // Reaction / reply path: associatedMessageGuid + associatedMessageType.
    if (associatedMessageGuid.length && associatedMessageType > 0) {
        // macOS 26 path (BlueBubblesHelper-verified, 13 args, no
        // balloonBundleID/payloadData/expressiveSendStyleID). BB allocates
        // and inits in two steps: `[[IMMessage alloc] init]` then call this
        // longer initializer on the result.
        SEL macos26Sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
        if ([messageClass instancesRespondToSelector:macos26Sel]) {
            unsigned long long flags = flagsForAssociatedMessagePayload(subject,
                                                                        fileTransferGuids,
                                                                        isAudioMessage);
            id msg = [[messageClass alloc] init];
            NSMethodSignature *sig =
                [messageClass instanceMethodSignatureForSelector:macos26Sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:macos26Sel];
            [inv setTarget:msg];
            id nilObj = nil;
            id messageGuid = clientMessageGuid.length ? clientMessageGuid : nilObj;
            NSDate *now = [NSDate date];
            [inv setArgument:&nilObj atIndex:2];           // sender
            [inv setArgument:&now atIndex:3];              // time
            [inv setArgument:&body atIndex:4];             // text
            [inv setArgument:&subject atIndex:5];          // messageSubject
            [inv setArgument:&fileTransferGuids atIndex:6];
            [inv setArgument:&flags atIndex:7];
            [inv setArgument:&nilObj atIndex:8];           // error
            [inv setArgument:&messageGuid atIndex:9];      // guid
            [inv setArgument:&nilObj atIndex:10];          // subject (string)
            [inv setArgument:&associatedMessageGuid atIndex:11];
            [inv setArgument:&associatedMessageType atIndex:12];
            [inv setArgument:&associatedMessageRange atIndex:13];
            [inv setArgument:&summaryInfo atIndex:14];
            [inv retainArguments];
            id result = invokeReturningObject(inv);
            debugLog(@"buildIMMessage: reaction via macos26Sel result=%@",
                     result ? NSStringFromClass([result class]) : @"(nil)");
            if (result) {
                if (threadIdentifier
                    && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                    [result performSelector:@selector(setThreadIdentifier:)
                                 withObject:threadIdentifier];
                }
                return result;
            }
        }

        // Legacy 17-arg form for older macOS.
        SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
        BOOL responds = [messageClass instancesRespondToSelector:sel];
        debugLog(@"buildIMMessage: reaction path; long-init responds=%d type=%lld guid=%@",
                 responds, associatedMessageType, associatedMessageGuid);
        id msg = [messageClass alloc];
        if ([msg respondsToSelector:sel]) {
            unsigned long long flags = flagsForAssociatedMessagePayload(subject,
                                                                        fileTransferGuids,
                                                                        isAudioMessage);
            NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:msg];
            id nilObj = nil;
            id messageGuid = clientMessageGuid.length ? clientMessageGuid : nilObj;
            NSDate *now = [NSDate date];
            [inv setArgument:&nilObj atIndex:2];        // sender
            [inv setArgument:&now atIndex:3];           // time
            [inv setArgument:&body atIndex:4];          // text
            [inv setArgument:&subject atIndex:5];       // messageSubject
            [inv setArgument:&fileTransferGuids atIndex:6];
            [inv setArgument:&flags atIndex:7];
            [inv setArgument:&nilObj atIndex:8];        // error
            [inv setArgument:&messageGuid atIndex:9];   // guid
            [inv setArgument:&nilObj atIndex:10];       // subject (string form)
            [inv setArgument:&nilObj atIndex:11];       // balloonBundleID
            [inv setArgument:&nilObj atIndex:12];       // payloadData
            [inv setArgument:&effectId atIndex:13];     // expressiveSendStyleID
            [inv setArgument:&associatedMessageGuid atIndex:14];
            [inv setArgument:&associatedMessageType atIndex:15];
            [inv setArgument:&associatedMessageRange atIndex:16];
            [inv setArgument:&summaryInfo atIndex:17];
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            if (threadIdentifier
                && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                [result performSelector:@selector(setThreadIdentifier:)
                             withObject:threadIdentifier];
            }
            return result;
        }
    }

    if (isReaction) {
        // Never degrade associated-message semantics into a normal send.
        return nil;
    }

    // Normal send / reply path. Try the BB-verified macOS 26 selector
    // (`initWithSender:…:expressiveSendStyleID:`, 12 args, no `IMMessage`
    // prefix) first; fall back to the legacy `initIMMessageWithSender:` for
    // older releases.
    SEL bbSendSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:);
    if ([messageClass instancesRespondToSelector:bbSendSel]) {
        unsigned long long flags = flagsForMessagePayload(subject, fileTransferGuids,
                                                          isAudioMessage);
        id m = [[messageClass alloc] init];
        NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:bbSendSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:bbSendSel];
        [inv setTarget:m];
        id nilObj = nil;
        id messageGuid = clientMessageGuid.length ? clientMessageGuid : nilObj;
        NSDate *now = [NSDate date];
        [inv setArgument:&nilObj atIndex:2];           // sender
        [inv setArgument:&now atIndex:3];              // time
        [inv setArgument:&body atIndex:4];             // text
        [inv setArgument:&subject atIndex:5];          // messageSubject
        [inv setArgument:&fileTransferGuids atIndex:6];
        [inv setArgument:&flags atIndex:7];
        [inv setArgument:&nilObj atIndex:8];           // error
        [inv setArgument:&messageGuid atIndex:9];      // guid
        [inv setArgument:&nilObj atIndex:10];          // subject string
        [inv setArgument:&nilObj atIndex:11];          // balloonBundleID
        [inv setArgument:&nilObj atIndex:12];          // payloadData
        [inv setArgument:&effectId atIndex:13];        // expressiveSendStyleID
        [inv retainArguments];
        id result = invokeReturningObject(inv);
        if (result) {
            if (threadIdentifier
                && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                [result performSelector:@selector(setThreadIdentifier:)
                             withObject:threadIdentifier];
            }
            if (!threadIdentifier.length) {
                clearReplyMetadataOnMessage(result);
            }
            return result;
        }
    }

    SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:);
    id msg = [messageClass alloc];
    if ([msg respondsToSelector:sel]) {
        unsigned long long flags = flagsForMessagePayload(subject, fileTransferGuids,
                                                          isAudioMessage);
        NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:msg];
        id nilObj = nil;
        id messageGuid = clientMessageGuid.length ? clientMessageGuid : nilObj;
        NSDate *now = [NSDate date];
        [inv setArgument:&nilObj atIndex:2];           // sender
        [inv setArgument:&now atIndex:3];              // time
        [inv setArgument:&body atIndex:4];             // text
        [inv setArgument:&subject atIndex:5];          // messageSubject
        [inv setArgument:&fileTransferGuids atIndex:6];
        [inv setArgument:&flags atIndex:7];
        [inv setArgument:&nilObj atIndex:8];           // error
        [inv setArgument:&messageGuid atIndex:9];      // guid
        [inv setArgument:&nilObj atIndex:10];          // subject string
        [inv setArgument:&nilObj atIndex:11];          // balloonBundleID
        [inv setArgument:&nilObj atIndex:12];          // payloadData
        [inv setArgument:&effectId atIndex:13];        // expressiveSendStyleID
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        if (!threadIdentifier.length) {
            clearReplyMetadataOnMessage(result);
        }
        return result;
    }

    // The simplest initializer cannot carry transfer GUIDs. An attachment
    // must fail closed instead of reporting a successful text-only send.
    if (hasAttachment || clientMessageGuid.length) return nil;

    // Last resort: simplest 2-arg initializer if the long form isn't available.
    SEL simple = @selector(initWithText:flags:);
    if ([msg respondsToSelector:simple]) {
        unsigned long long flags = 0x100005ULL;
        NSMethodSignature *sig2 = [messageClass instanceMethodSignatureForSelector:simple];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig2];
        [inv setSelector:simple];
        [inv setTarget:msg];
        [inv setArgument:&body atIndex:2];
        [inv setArgument:&flags atIndex:3];
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        if (!threadIdentifier.length) {
            clearReplyMetadataOnMessage(result);
        }
        return result;
    }
    return nil;
}

/// Look up a chat item by message guid. Tries BlueBubblesHelper's
/// block-based `loadMessageWithGUID:completionBlock:` first — that path
/// works for messages older than what's currently loaded into the live
/// `chat.chatItems` window. Falls back to the older
/// `loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:` + sync poll
/// for OSes that don't expose the block-based load.
