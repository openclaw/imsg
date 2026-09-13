#pragma mark - IMMessage Builder

/// Invoke a class method that returns an object, returning a strongly
/// retained id. NSInvocation returns object references without transferring
/// ownership, so we read into an `__unsafe_unretained` slot then assign to a
/// strong variable to balance ARC.
static id invokeReturningObject(NSInvocation *inv) {
    __unsafe_unretained id raw = nil;
    [inv invoke];
    [inv getReturnValue:&raw];
    return raw;
}

/// Apply optional metadata fields directly onto the IMMessageItem before
/// the IMMessage wrap. Setters on a wrapped IMMessage's `_imMessageItem`
/// don't persist (the wrap returns a transient item rebuilt each call), so
/// extended fields like `expressiveSendStyleID` and `associatedMessageGUID`
/// must be applied here, ahead of the wrap.
static void applyItemExtendedFields(id item,
                                    NSAttributedString *subject,
                                    NSString *effectId,
                                    NSString *associatedMessageGuid,
                                    long long associatedMessageType,
                                    NSRange associatedMessageRange,
                                    NSDictionary *summaryInfo) {
    if (!item) return;
    if (subject.length
        && [item respondsToSelector:@selector(setMessageSubject:)]) {
        [item performSelector:@selector(setMessageSubject:) withObject:subject];
    }
    if (effectId.length
        && [item respondsToSelector:@selector(setExpressiveSendStyleID:)]) {
        [item performSelector:@selector(setExpressiveSendStyleID:)
                   withObject:effectId];
    }
    if (associatedMessageGuid.length && associatedMessageType > 0) {
        if ([item respondsToSelector:@selector(setAssociatedMessageGUID:)]) {
            [item performSelector:@selector(setAssociatedMessageGUID:)
                       withObject:associatedMessageGuid];
        }
        if ([item respondsToSelector:@selector(setAssociatedMessageType:)]) {
            NSMethodSignature *sig = [item methodSignatureForSelector:
                @selector(setAssociatedMessageType:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setAssociatedMessageType:)];
            [inv setTarget:item];
            [inv setArgument:&associatedMessageType atIndex:2];
            [inv invoke];
        }
        if ([item respondsToSelector:@selector(setAssociatedMessageRange:)]) {
            NSMethodSignature *sig = [item methodSignatureForSelector:
                @selector(setAssociatedMessageRange:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setAssociatedMessageRange:)];
            [inv setTarget:item];
            NSRange range = associatedMessageRange;
            [inv setArgument:&range atIndex:2];
            [inv invoke];
        }
    }
    if (summaryInfo
        && [item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
        [item performSelector:@selector(setMessageSummaryInfo:)
                   withObject:summaryInfo];
    }
}

static void ensureItemBodyData(id item, NSAttributedString *attributedText) {
    if (!item || attributedText.length == 0) return;
    NSData *bodyData = [item respondsToSelector:@selector(bodyData)]
        ? [item performSelector:@selector(bodyData)] : nil;
    if (bodyData.length > 0 || ![item respondsToSelector:@selector(setBodyData:)]) {
        return;
    }

    @try {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSData *typedstream = [NSArchiver archivedDataWithRootObject:attributedText];
        #pragma clang diagnostic pop
        if (typedstream.length > 0) {
            [item performSelector:@selector(setBodyData:) withObject:typedstream];
        }
    } @catch (NSException *e) {
        // NSArchiver chokes on NSPresentationIntent attributes that some
        // markdown initializers emit. Retry with a plain copy.
        NSMutableAttributedString *plain = [[NSMutableAttributedString alloc]
            initWithString:[attributedText string]];
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSData *plainData = [NSArchiver archivedDataWithRootObject:plain];
            #pragma clang diagnostic pop
            [item performSelector:@selector(setBodyData:) withObject:plainData];
        } @catch (__unused NSException *e2) {
            // Give up; the wrap below may still succeed for non-empty cases.
        }
    }
}

static void clearReplyMetadataOnObject(id object) {
    if (!object) return;
    NSArray<NSString *> *objectSelectors = @[
        @"setReplyToGUID:",
        @"setThreadIdentifier:",
        @"setThreadOriginator:",
        @"setThreadOriginatorGUID:",
        @"setThreadOriginatorPart:"
    ];
    id nilObject = nil;
    for (NSString *selectorName in objectSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector]) {
            @try {
                [object performSelector:selector withObject:nilObject];
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL associatedTypeSelector = @selector(setAssociatedMessageType:);
    if ([object respondsToSelector:associatedTypeSelector]) {
        @try {
            NSMethodSignature *sig =
                [object methodSignatureForSelector:associatedTypeSelector];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:associatedTypeSelector];
            [inv setTarget:object];
            long long zero = 0;
            [inv setArgument:&zero atIndex:2];
            [inv invoke];
        } @catch (__unused NSException *exception) {}
    }
    SEL associatedGuidSelector = @selector(setAssociatedMessageGUID:);
    if ([object respondsToSelector:associatedGuidSelector]) {
        @try {
            [object performSelector:associatedGuidSelector withObject:nilObject];
        } @catch (__unused NSException *exception) {}
    }
}

static void clearReplyMetadataOnMessage(id message) {
    clearReplyMetadataOnObject(message);
    SEL itemSel = NSSelectorFromString(@"_imMessageItem");
    if ([message respondsToSelector:itemSel]) {
        @try {
            id item = [message performSelector:itemSel];
            clearReplyMetadataOnObject(item);
        } @catch (__unused NSException *exception) {}
    }
}

/// Build an IMMessageItem with the body set up-front, apply any extended
/// metadata fields onto the item, then wrap with IMMessage. On macOS 26 the
/// high-level `+initIMMessageWith…` factories build a transient
/// IMMessageItem on demand whose `body` / `bodyData` don't survive
/// `[chat sendMessage:]` — imagent reads `bodyData` from the underlying
/// item, sees nothing, and silently drops the message. Building the item
/// up-front and seeding `bodyData` via NSArchiver is the only path that
/// lands on macOS 26. Returns nil if the required selectors are missing
/// (older OSes; caller should fall back).
static id constructIMMessageViaItem(NSAttributedString *attributedText,
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
                                    NSString *clientMessageGuid) {
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (!IMMessageClass || !IMMessageItemClass) return nil;

    SEL itemInitSel = @selector(initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:);
    if (![IMMessageItemClass instancesRespondToSelector:itemInitSel]) return nil;

    SEL wrapSel = @selector(messageFromIMMessageItem:sender:subject:);
    if (![IMMessageClass respondsToSelector:wrapSel]) return nil;

    id item = [IMMessageItemClass alloc];
    if (!item) return nil;

    NSDate *now = [NSDate date];
    NSArray *transferGuids = fileTransferGuids ?: @[];
    NSError *err = nil;
    NSString *guid = clientMessageGuid.length
        ? clientMessageGuid
        : [[NSUUID UUID] UUIDString];
    // BlueBubblesHelper-verified flag set: 0x100005 (FromMe | Finished |
    // 0x100000 finalize bit) for normal text+attachment, 0x10000d when a
    // subject is set, 0x300005 for audio messages. The earlier `0x5`
    // variant was the cause of malformed attachments on the receiver — the
    // 0x100000 bit is what tells imagent to finalize the payload.
    unsigned long long flags;
    if (isAudioMessage) {
        flags = 0x300005ULL;
    } else if (subject.length) {
        flags = 0x10000dULL;
    } else {
        flags = 0x100005ULL;
    }
    id sender = nil;
    NSDictionary *attributes = nil;
    NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

    NSMethodSignature *isig =
        [IMMessageItemClass instanceMethodSignatureForSelector:itemInitSel];
    NSInvocation *iinv = [NSInvocation invocationWithMethodSignature:isig];
    [iinv setSelector:itemInitSel];
    [iinv setTarget:item];
    [iinv setArgument:&sender atIndex:2];
    [iinv setArgument:&now atIndex:3];
    [iinv setArgument:&attributedText atIndex:4];
    [iinv setArgument:&attributes atIndex:5];
    [iinv setArgument:&transferGuids atIndex:6];
    [iinv setArgument:&flags atIndex:7];
    [iinv setArgument:&err atIndex:8];
    [iinv setArgument:&guid atIndex:9];
    [iinv setArgument:&messageThreadIdentifier atIndex:10];
    [iinv retainArguments];
    item = invokeReturningObject(iinv);
    if (!item) return nil;

    if ([item respondsToSelector:@selector(_regenerateBodyData)]) {
        [item performSelector:@selector(_regenerateBodyData)];
    }

    // imagent reads bodyData (NSArchiver typedstream). On macOS 26 the
    // initWithSender: path leaves bodyData empty; force-archive the
    // attributed string ourselves so the daemon has a payload to ship.
    ensureItemBodyData(item, attributedText);

    // Set extended fields on the item BEFORE wrapping. The IMMessage wrap's
    // `_imMessageItem` accessor returns a transient item rebuilt each call,
    // so post-wrap setters don't persist (per the macOS 26 behavior 10ce6ab
    // documented).
    applyItemExtendedFields(item, subject, effectId,
                            associatedMessageGuid, associatedMessageType,
                            associatedMessageRange, summaryInfo);
    BOOL standalone = !threadIdentifier.length
        && !threadOriginator
        && !associatedMessageGuid.length
        && associatedMessageType == 0;
    if (standalone) {
        clearReplyMetadataOnObject(item);
    }
    if (threadOriginator
        && [item respondsToSelector:@selector(setThreadOriginator:)]) {
        [item performSelector:@selector(setThreadOriginator:)
                   withObject:threadOriginator];
    }

    NSMethodSignature *wsig =
        [IMMessageClass methodSignatureForSelector:wrapSel];
    NSInvocation *winv = [NSInvocation invocationWithMethodSignature:wsig];
    [winv setSelector:wrapSel];
    [winv setTarget:IMMessageClass];
    id nilSender = nil;
    id nilSubject = nil;
    [winv setArgument:&item atIndex:2];
    [winv setArgument:&nilSender atIndex:3];
    [winv setArgument:&nilSubject atIndex:4];
    [winv retainArguments];
    id result = invokeReturningObject(winv);
    if (standalone) {
        clearReplyMetadataOnMessage(result);
    }
    return result;
}

/// Load the parent message for a reply via IMChatHistoryController and derive
/// the thread identifier Messages uses for native inline replies. This follows
/// the BlueBubbles IMCore shape: reuse the parent's existing thread identifier
/// when present, otherwise derive one from the matching message-part chat item.
