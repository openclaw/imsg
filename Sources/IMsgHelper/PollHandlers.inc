static NSDictionary *handleSendPoll(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *question = trimmedPollString(params[@"question"]);
    NSArray *rawOptions = params[@"options"];
    NSString *creatorHandle = trimmedPollString(params[@"creatorHandle"]);
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!question.length) return errorResponse(requestId, @"Missing question");
    if (![rawOptions isKindOfClass:[NSArray class]]) {
        return errorResponse(requestId, @"Missing options array");
    }

    NSArray<NSString *> *options = normalizedPollOptions(rawOptions);
    if (options.count < 2) {
        return errorResponse(requestId, @"Poll requires at least two options");
    }
    if (!pollPayloadMessageInitializerAvailable()) {
        return errorResponse(requestId, @"Poll IMMessage initializer unavailable on this macOS");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    if (!creatorHandle.length) {
        creatorHandle = activeIMessageSenderHandle();
    }
    if (!creatorHandle.length) {
        return errorResponse(requestId,
            @"Could not resolve active iMessage sender handle for poll payload");
    }

    NSString *sessionIdentifier = nil;
    NSArray<NSString *> *optionIdentifiers = nil;
    NSString *payloadError = nil;
    NSData *payloadData = buildPollCreationPayloadData(question,
                                                       options,
                                                       creatorHandle,
                                                       &sessionIdentifier,
                                                       &optionIdentifiers,
                                                       &payloadError);
    if (!payloadData) {
        return errorResponse(requestId, payloadError ?: @"Could not build poll payload");
    }

    NSDictionary *summary = @{ @"enc": @YES, @"ust": @YES };
    NSAttributedString *body = buildPollBreadcrumbAttributed();
    id parentMessage = nil;
    id parentItem = nil;
    id parentChatItem = nil;
    NSString *threadIdentifier = nil;
    NSString *threadOriginatorPart = nil;
    NSString *replyToGUID = selectedMessageGuid;
    NSString *threadOriginatorGUID = selectedMessageGuid;
    if (selectedMessageGuid.length) {
        threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                  &parentMessage,
                                                  &parentItem);
        parentChatItem = loadParentFirstChatItem(selectedMessageGuid, NULL);
        threadOriginatorPart = threadOriginatorPartForChatItem(parentChatItem ?: parentItem);
        debugLog(@"handleSendPoll: parent=%@ threadId=%@",
                 selectedMessageGuid, threadIdentifier ?: @"(none)");
        if (!threadIdentifier.length || !parentMessage || !parentItem) {
            return errorResponse(requestId,
                [NSString stringWithFormat:
                    @"Could not resolve reply target for poll: %@", selectedMessageGuid]);
        }
    } else {
        clearThreadContextForChat(chat, nil);
    }

    @try {
        id imMessage = buildPollIMMessage(body,
                                          payloadData,
                                          summary,
                                          threadIdentifier,
                                          replyToGUID,
                                          threadOriginatorGUID,
                                          threadOriginatorPart,
                                          parentItem);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct poll IMMessage");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        applyThreadOriginatorGUIDHints(imMessage,
                                       selectedMessageGuid,
                                       threadOriginatorPart);
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = outgoingMessageGuid(imMessage);

        NSMutableArray *optionPayloads = [NSMutableArray array];
        for (NSUInteger i = 0; i < options.count; i++) {
            NSString *identifier = optionIdentifiers.count > i ? optionIdentifiers[i] : @"";
            [optionPayloads addObject:@{@"id": identifier, @"text": options[i]}];
        }

        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"poll": @{
                @"kind": @"created",
                @"event": @"imessage.poll.created",
                @"question": question,
                @"options": optionPayloads,
                @"sessionIdentifier": sessionIdentifier ?: @""
            },
            @"balloonBundleID": pollsBalloonBundleIdentifier()
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-poll failed: %@", exception.reason]);
    }
}

/// Build the vote payload: a data URL carrying the vote JSON, wrapped in the
/// same archived envelope as poll creation. Mirrors Apple's native vote shape
/// (verified against a real received vote): {"version":1,"item":{"votes":
/// [{"voteOptionIdentifier":...,"participantHandle":...}]}}. Unlike poll
/// creation the data URL carries no `?src=p&c=` suffix.
static NSData *buildPollVotePayloadData(NSString *optionIdentifier,
                                        NSString *voterHandle,
                                        NSArray<NSString *> *remainingOptionIdentifiers,
                                        BOOL removed,
                                        NSString **outError) {
    NSArray<NSString *> *voteOptionIdentifiers = removed
        ? (remainingOptionIdentifiers ?: @[])
        : @[(optionIdentifier ?: @"")];
    NSMutableArray *votes = [NSMutableArray arrayWithCapacity:voteOptionIdentifiers.count];
    NSString *participantHandle = pollParticipantHandle(voterHandle) ?: @"";
    for (NSString *identifierValue in voteOptionIdentifiers) {
        NSString *identifier = trimmedPollString(identifierValue);
        if (!identifier.length) {
            if (outError) *outError = @"Poll vote payload contains an empty option identifier";
            return nil;
        }
        [votes addObject:@{
            @"voteOptionIdentifier": identifier,
            @"participantHandle": participantHandle
        }];
    }
    NSDictionary *root = @{
        @"version": @1,
        @"item": @{ @"votes": votes }
    };
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!jsonData) {
        if (outError) *outError = jsonError.localizedDescription ?: @"Could not encode vote payload";
        return nil;
    }
    if (jsonData.length > 4096) {
        if (outError) *outError = @"Poll vote payload exceeds 4096 bytes";
        return nil;
    }
    NSString *encoded = [jsonData base64EncodedStringWithOptions:0];
    NSString *urlString = [NSString stringWithFormat:@"data:,%@", encoded];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = @"Could not create vote URL";
        return nil;
    }
    NSUUID *sessionIdentifier = [NSUUID UUID];
    NSError *archiveError = nil;
    NSData *payload = archivePollMutationEnvelope(url, sessionIdentifier, &archiveError);
    if (!payload && outError) {
        *outError = archiveError.localizedDescription ?: @"Could not archive vote payload";
    }
    return payload;
}

/// Construct a poll-vote IMMessage: a Polls balloon carrying the vote payload,
/// associated to the original poll via a bare poll GUID + associatedMessageType
/// 4000. Native votes (verified against chat.db) use a bare poll GUID, not the
/// `p:<part>/<guid>` form tapbacks use.
///
/// The associated-message initializer persists the poll link atomically. Its
/// backing item then receives the balloon payload; wrapping an item first loses
/// the association on macOS 26.
static id buildPollVoteIMMessage(NSAttributedString *body,
                                 NSData *payloadData,
                                 NSDictionary *summaryInfo,
                                 NSString *pollMessageGuid,
                                 long long associatedType) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;

    // No macOS 26 initializer carries the payload and association together.
    // Build the association atomically, then stamp payload metadata across the
    // message and backing item; macOS 26.4 splits the setters between them.
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
    if (![messageClass instancesRespondToSelector:sel]) return nil;

    id msg = [messageClass alloc];
    NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:msg];

    id nilObj = nil;
    NSDate *now = [NSDate date];
    NSArray *fileTransferGuids = @[];
    unsigned long long flags = flagsForAssociatedMessagePayload(nil, fileTransferGuids, NO);
    NSRange associatedRange = NSMakeRange(0, 1);

    [inv setArgument:&nilObj atIndex:2];            // sender
    [inv setArgument:&now atIndex:3];               // time
    [inv setArgument:&body atIndex:4];              // text
    [inv setArgument:&nilObj atIndex:5];            // messageSubject
    [inv setArgument:&fileTransferGuids atIndex:6];
    [inv setArgument:&flags atIndex:7];
    [inv setArgument:&nilObj atIndex:8];            // error
    [inv setArgument:&nilObj atIndex:9];            // guid
    [inv setArgument:&nilObj atIndex:10];           // subject (string)
    [inv setArgument:&pollMessageGuid atIndex:11];
    [inv setArgument:&associatedType atIndex:12];
    [inv setArgument:&associatedRange atIndex:13];
    [inv setArgument:&summaryInfo atIndex:14];
    [inv retainArguments];
    id result = invokeReturningObject(inv);
    if (!result) return nil;

    NSString *balloonID = pollsBalloonBundleIdentifier();
    NSArray<id> *targets = @[result];
    SEL itemSel = NSSelectorFromString(@"_imMessageItem");
    if ([result respondsToSelector:itemSel]) {
        @try {
            id item = [result performSelector:itemSel];
            if (item) targets = @[item, result];
        } @catch (__unused NSException *e) {}
    }
    BOOL balloonStamped = NO;
    BOOL payloadStamped = NO;
    for (id target in targets) {
        if ([target respondsToSelector:@selector(setBalloonBundleID:)]) {
            [target performSelector:@selector(setBalloonBundleID:) withObject:balloonID];
            balloonStamped = YES;
        }
        if ([target respondsToSelector:@selector(setPayloadData:)]) {
            [target performSelector:@selector(setPayloadData:) withObject:payloadData];
            payloadStamped = YES;
        }
    }
    return (balloonStamped && payloadStamped) ? result : nil;
}

static NSDictionary *handleSendPollVoteMutation(NSInteger requestId,
                                                NSDictionary *params,
                                                BOOL removed) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *pollMessageGuid = trimmedPollString(params[@"pollMessageGuid"]);
    NSString *optionIdentifier = trimmedPollString(params[@"optionIdentifier"]);
    NSString *optionText = trimmedPollString(params[@"optionText"]);
    NSArray *remainingOptionIdentifiers = @[];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!pollMessageGuid.length) return errorResponse(requestId, @"Missing pollMessageGuid");
    if (!optionIdentifier.length) return errorResponse(requestId, @"Missing optionIdentifier");
    if (removed) {
        id rawRemaining = params[@"remainingOptionIdentifiers"];
        if (rawRemaining && ![rawRemaining isKindOfClass:[NSArray class]]) {
            return errorResponse(requestId, @"remainingOptionIdentifiers must be an array");
        }
        NSMutableArray *normalizedRemaining = [NSMutableArray array];
        for (id rawIdentifier in (NSArray *)(rawRemaining ?: @[])) {
            if (![rawIdentifier isKindOfClass:[NSString class]]) {
                return errorResponse(requestId, @"remainingOptionIdentifiers must contain strings");
            }
            NSString *identifier = trimmedPollString(rawIdentifier);
            if (!identifier.length) {
                return errorResponse(requestId, @"remainingOptionIdentifiers must not contain empty values");
            }
            [normalizedRemaining addObject:identifier];
        }
        remainingOptionIdentifiers = [normalizedRemaining copy];
    }
    if (!pollVoteMessageInitializerAvailable()) {
        return errorResponse(requestId, @"Poll vote IMMessage initializer unavailable on this macOS");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSString *voterHandle = activeIMessageSenderHandle();
    if (!voterHandle.length) {
        return errorResponse(requestId,
            @"Could not resolve active iMessage sender handle for vote payload");
    }

    NSString *payloadError = nil;
    NSData *payloadData = buildPollVotePayloadData(optionIdentifier,
                                                   voterHandle,
                                                   remainingOptionIdentifiers,
                                                   removed,
                                                   &payloadError);
    if (!payloadData) {
        return errorResponse(requestId, payloadError ?: @"Could not build vote payload");
    }

    NSDictionary *summary = @{
        @"amc": @9,
        @"enc": @YES,
        @"amd": @"Polls",
        @"ust": @YES,
        @"ams": @"Sent a vote",
        @"amb": pollsBalloonBundleIdentifier()
    };
    NSAttributedString *body = buildPollBreadcrumbAttributed();

    @try {
        clearThreadContextForChat(chat, nil);
        id imMessage = buildPollVoteIMMessage(body, payloadData, summary, pollMessageGuid, 4000);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct vote IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"pollMessageGuid": pollMessageGuid,
            @"optionIdentifier": optionIdentifier,
            @"optionText": optionText ?: @"",
            @"remainingOptionIdentifiers": remainingOptionIdentifiers,
            @"removed": @(removed),
            @"balloonBundleID": pollsBalloonBundleIdentifier()
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-poll-vote failed: %@", exception.reason]);
    }
}

/// `send-poll-vote`: cast a vote on an existing poll. Builds a Polls balloon
/// carrying the vote payload, associated to the poll message via type 4000.
/// The caller passes the original poll message GUID and the chosen option's
/// UUID (resolved CLI-side from the poll's decoded options).
static NSDictionary *handleSendPollVote(NSInteger requestId, NSDictionary *params) {
    return handleSendPollVoteMutation(requestId, params, NO);
}

/// `send-poll-unvote`: remove one selected option by sending the same native
/// vote payload shape with the sender's remaining selected options.
static NSDictionary *handleSendPollUnvote(NSInteger requestId, NSDictionary *params) {
    return handleSendPollVoteMutation(requestId, params, YES);
}

/// `send-multipart`: at minimum, sends an attributedBody composed of multiple
/// text parts. v1 supports text-only multipart; mention/file parts can land in
/// a follow-up.
