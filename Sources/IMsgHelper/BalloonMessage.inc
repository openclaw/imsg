static id buildBalloonIMMessage(NSString *balloonID,
                                NSAttributedString *body,
                                NSData *payloadData,
                                NSDictionary *summaryInfo,
                                NSArray *fileTransferGuids,
                                NSString *threadIdentifier,
                                NSString *replyToGUID,
                                NSString *threadOriginatorGUID,
                                NSString *threadOriginatorPart,
                                id parentItem) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;
    if (!balloonID.length) return nil;

    if (replyToGUID.length) {
        Class itemClass = NSClassFromString(@"IMMessageItem");
        SEL itemInitSel = @selector(initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:);
        SEL wrapSel = @selector(messageFromIMMessageItem:sender:subject:);
        if (!itemClass
            || ![itemClass instancesRespondToSelector:itemInitSel]
            || ![messageClass respondsToSelector:wrapSel]) {
            return nil;
        }

        id item = [itemClass alloc];
        if (!item) return nil;

        NSDate *now = [NSDate date];
        NSArray *transferGuids = fileTransferGuids ?: @[];
        unsigned long long flags = flagsForMessagePayload(nil, transferGuids, NO);
        NSError *err = nil;
        NSString *guid = [[NSUUID UUID] UUIDString];
        id sender = nil;
        NSDictionary *attributes = nil;
        NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

        NSMethodSignature *isig = [itemClass instanceMethodSignatureForSelector:itemInitSel];
        NSInvocation *iinv = [NSInvocation invocationWithMethodSignature:isig];
        [iinv setSelector:itemInitSel];
        [iinv setTarget:item];
        [iinv setArgument:&sender atIndex:2];
        [iinv setArgument:&now atIndex:3];
        [iinv setArgument:&body atIndex:4];
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
        ensureItemBodyData(item, body);

        if (![item respondsToSelector:@selector(setBalloonBundleID:)]
            || ![item respondsToSelector:@selector(setPayloadData:)]
            || ![item respondsToSelector:@selector(setReplyToGUID:)]) {
            return nil;
        }
        if (summaryInfo
            && ![item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
            return nil;
        }
        if (messageThreadIdentifier
            && ![item respondsToSelector:@selector(setThreadIdentifier:)]) {
            return nil;
        }
        if (parentItem
            && ![item respondsToSelector:@selector(setThreadOriginator:)]) {
            return nil;
        }
        [item performSelector:@selector(setBalloonBundleID:) withObject:balloonID];
        [item performSelector:@selector(setPayloadData:) withObject:payloadData];
        [item performSelector:@selector(setReplyToGUID:) withObject:replyToGUID];
        if (summaryInfo
            && [item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
            [item performSelector:@selector(setMessageSummaryInfo:)
                       withObject:summaryInfo];
        }
        if (messageThreadIdentifier
            && [item respondsToSelector:@selector(setThreadIdentifier:)]) {
            [item performSelector:@selector(setThreadIdentifier:)
                       withObject:messageThreadIdentifier];
        }
        if (parentItem
            && [item respondsToSelector:@selector(setThreadOriginator:)]) {
            [item performSelector:@selector(setThreadOriginator:)
                       withObject:parentItem];
        }
        if (threadOriginatorGUID.length) {
            SEL sel = NSSelectorFromString(@"setThreadOriginatorGUID:");
            if ([item respondsToSelector:sel]) {
                [item performSelector:sel withObject:threadOriginatorGUID];
            }
        }
        if (threadOriginatorPart.length) {
            SEL sel = NSSelectorFromString(@"setThreadOriginatorPart:");
            if ([item respondsToSelector:sel]) {
                [item performSelector:sel withObject:threadOriginatorPart];
            }
        }

        NSMethodSignature *wsig = [messageClass methodSignatureForSelector:wrapSel];
        NSInvocation *winv = [NSInvocation invocationWithMethodSignature:wsig];
        [winv setSelector:wrapSel];
        [winv setTarget:messageClass];
        id nilSender = nil;
        id nilSubject = nil;
        [winv setArgument:&item atIndex:2];
        [winv setArgument:&nilSender atIndex:3];
        [winv setArgument:&nilSubject atIndex:4];
        [winv retainArguments];
        return invokeReturningObject(winv);
    }

    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:);
    if (![messageClass instancesRespondToSelector:sel]) return nil;

    id msg = [[messageClass alloc] init];
    NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:msg];

    id nilObj = nil;
    NSDate *now = [NSDate date];
    NSArray *transferGuids = fileTransferGuids ?: @[];
    unsigned long long flags = flagsForMessagePayload(nil, transferGuids, NO);
    unsigned long long scheduleType = 0;
    unsigned long long scheduleState = 0;
    NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

    [inv setArgument:&nilObj atIndex:2];              // sender
    [inv setArgument:&now atIndex:3];                 // time
    [inv setArgument:&body atIndex:4];                // text
    [inv setArgument:&nilObj atIndex:5];              // messageSubject
    [inv setArgument:&transferGuids atIndex:6];
    [inv setArgument:&flags atIndex:7];
    [inv setArgument:&nilObj atIndex:8];              // error
    [inv setArgument:&nilObj atIndex:9];              // guid
    [inv setArgument:&nilObj atIndex:10];             // subject string
    [inv setArgument:&balloonID atIndex:11];
    [inv setArgument:&payloadData atIndex:12];
    [inv setArgument:&nilObj atIndex:13];             // expressiveSendStyleID
    [inv setArgument:&messageThreadIdentifier atIndex:14];
    [inv setArgument:&scheduleType atIndex:15];
    [inv setArgument:&scheduleState atIndex:16];
    [inv setArgument:&summaryInfo atIndex:17];
    [inv retainArguments];
    id result = invokeReturningObject(inv);
    if (!messageThreadIdentifier.length) {
        clearReplyMetadataOnMessage(result);
    }
    return result;
}

static id buildPollIMMessage(NSAttributedString *body,
                             NSData *payloadData,
                             NSDictionary *summaryInfo,
                             NSString *threadIdentifier,
                             NSString *replyToGUID,
                             NSString *threadOriginatorGUID,
                             NSString *threadOriginatorPart,
                             id parentItem) {
    return buildBalloonIMMessage(pollsBalloonBundleIdentifier(),
                                 body,
                                 payloadData,
                                 summaryInfo,
                                 @[],
                                 threadIdentifier,
                                 replyToGUID,
                                 threadOriginatorGUID,
                                 threadOriginatorPart,
                                 parentItem);
}

