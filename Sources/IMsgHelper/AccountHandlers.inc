#pragma mark - Introspection Handlers (v2)

static NSDictionary *handleSearchMessages(NSInteger requestId, NSDictionary *params) {
    NSString *query = params[@"query"];
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return errorResponse(requestId, @"Missing query");
    }
    // Spotlight-style search across loaded chat items via IMChatHistoryController
    // is not exposed to us cleanly without private headers; return a structured
    // not-implemented response so the CLI can degrade gracefully.
    return successResponse(requestId, @{
        @"query": query,
        @"results": @[],
        @"note": @"server-side search not yet implemented; falls back to chat.db"
    });
}

static NSDictionary *handleGetAccountInfo(NSInteger requestId, NSDictionary *params) {
    Class accClass = NSClassFromString(@"IMAccountController");
    if (!accClass) return errorResponse(requestId, @"IMAccountController unavailable");
    id ctrl = [accClass performSelector:@selector(sharedInstance)];
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if ([ctrl respondsToSelector:@selector(activeIMessageAccount)]) {
        id account = [ctrl performSelector:@selector(activeIMessageAccount)];
        if (account) {
            NSArray *aliases = nil;
            if ([account respondsToSelector:@selector(vettedAliases)]) {
                aliases = [account performSelector:@selector(vettedAliases)];
            }
            id login = nil;
            if ([account respondsToSelector:@selector(loginIMHandle)]) {
                login = [account performSelector:@selector(loginIMHandle)];
            }
            NSString *loginID = nil;
            if (login && [login respondsToSelector:@selector(ID)]) {
                loginID = [login performSelector:@selector(ID)];
            }
            info[@"vetted_aliases"] = aliases ?: @[];
            info[@"login"] = loginID ?: @"";
            info[@"service"] = @"iMessage";
        }
    }
    return successResponse(requestId, info);
}

static id sharedNicknameController(void) {
    Class nnClass = NSClassFromString(@"IMNicknameController");
    SEL sharedSelector = @selector(sharedInstance);
    if (!nnClass || ![(id)nnClass respondsToSelector:sharedSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(nnClass, sharedSelector);
}

static BOOL waitForNicknameControllerLoad(id controller, NSTimeInterval timeout) {
    SEL loadedSelector = @selector(isInitialLoadComplete);
    if (![controller respondsToSelector:loadedSelector]) return YES;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!((BOOL (*)(id, SEL))objc_msgSend)(controller, loadedSelector)) {
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        NSDate *nextCheck = [NSDate dateWithTimeIntervalSinceNow:0.05];
        if ([NSThread isMainThread]) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:nextCheck];
        } else {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    return YES;
}

static NSString *nicknameSharingMutationSelectorName(Class nnClass) {
    if (!nnClass) return nil;
    NSString *selectorName =
        @"allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:";
    return [nnClass instancesRespondToSelector:NSSelectorFromString(selectorName)]
        ? selectorName
        : nil;
}

static NSDictionary *nicknameSharingSelectorStatus(void) {
    Class nnClass = NSClassFromString(@"IMNicknameController");
    BOOL hasSharedInstance = nnClass && [(id)nnClass respondsToSelector:@selector(sharedInstance)];
    BOOL hasLookup = nnClass &&
        [nnClass instancesRespondToSelector:@selector(nicknameForHandle:)];
    BOOL hasShouldOffer = nnClass &&
        [nnClass instancesRespondToSelector:@selector(shouldOfferNicknameSharingForChat:)];
    NSString *shareSelector = nicknameSharingMutationSelectorName(nnClass);
    return @{
        @"controller": @(hasSharedInstance),
        @"nickname_lookup": @(hasSharedInstance && hasLookup),
        @"should_offer": @(hasSharedInstance && hasShouldOffer),
        @"share": @(hasSharedInstance && shareSelector != nil),
        @"share_selector": shareSelector ?: [NSNull null]
    };
}

static IMAccount *activeIMessageAccount(void) {
    Class accountControllerClass = NSClassFromString(@"IMAccountController");
    id accountController = accountControllerClass &&
            [(id)accountControllerClass respondsToSelector:@selector(sharedInstance)]
        ? ((id (*)(id, SEL))objc_msgSend)(accountControllerClass, @selector(sharedInstance))
        : nil;
    if ([accountController respondsToSelector:@selector(activeIMessageAccount)]) {
        return ((id (*)(id, SEL))objc_msgSend)(accountController,
                                               @selector(activeIMessageAccount));
    }
    return nil;
}

static NSString *nicknameLoginHandleID(IMAccount *account) {
    if (![account respondsToSelector:@selector(loginIMHandle)]) return nil;
    id loginHandle = ((id (*)(id, SEL))objc_msgSend)(account, @selector(loginIMHandle));
    if (![loginHandle respondsToSelector:@selector(ID)]) return nil;
    id handleID = ((id (*)(id, SEL))objc_msgSend)(loginHandle, @selector(ID));
    return [handleID isKindOfClass:[NSString class]] && [handleID length] ? handleID : nil;
}

static NSString *nicknameSenderHandleID(IMChat *chat, NSString **source) {
    if ([chat respondsToSelector:@selector(lastAddressedHandleID)]) {
        id handleID = ((id (*)(id, SEL))objc_msgSend)(chat, @selector(lastAddressedHandleID));
        if ([handleID isKindOfClass:[NSString class]] && [handleID length]) {
            if (source) *source = @"chat.lastAddressedHandleID";
            return handleID;
        }
    }

    IMAccount *chatAccount = [chat respondsToSelector:@selector(account)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(account))
        : nil;
    NSString *chatLoginHandleID = nicknameLoginHandleID(chatAccount);
    if (chatLoginHandleID.length) {
        if (source) *source = @"chat.account.loginIMHandle";
        return chatLoginHandleID;
    }
    return nil;
}

static NSDictionary *handleGetNicknameInfo(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return errorResponse(requestId, @"Missing address");
    }

    @try {
        id controller = sharedNicknameController();
        if (!controller) return errorResponse(requestId, @"IMNicknameController unavailable");
        if (![controller respondsToSelector:@selector(nicknameForHandle:)]) {
            return errorResponse(requestId, @"nicknameForHandle: unavailable");
        }

        IMAccount *account = activeIMessageAccount();
        if (![account respondsToSelector:@selector(imHandleWithID:)]) {
            return errorResponse(requestId, @"Active iMessage account unavailable");
        }
        id handle = ((id (*)(id, SEL, id))objc_msgSend)(account,
                                                        @selector(imHandleWithID:), address);
        if (!handle) return errorResponse(requestId, @"Could not resolve iMessage handle");

        id nickname = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                                                           @selector(nicknameForHandle:), handle);
        NSMutableDictionary *info = [@{
            @"address": address,
            @"has_nickname": @(nickname != nil)
        } mutableCopy];
        if (nickname) info[@"description"] = [nickname description] ?: @"";
        return successResponse(requestId, info);
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Nickname lookup failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }
}

static NSDictionary *handleShouldOfferNicknameSharing(NSInteger requestId,
                                                       NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return errorResponse(requestId, @"Missing chatGuid");
    }
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Name & Photo sharing requires an iMessage chat");
    }

    Class nnClass = NSClassFromString(@"IMNicknameController");
    NSDictionary *capabilities = nicknameSharingSelectorStatus();
    id controller = nil;
    @try {
        controller = sharedNicknameController();
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Name & Photo controller failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }

    NSArray *participants = [chat respondsToSelector:@selector(participants)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(participants))
        : @[];
    NSString *senderSource = nil;
    NSString *senderHandleID = nicknameSenderHandleID(chat, &senderSource);
    BOOL controllerLoaded = controller != nil && waitForNicknameControllerLoad(controller, 1.0);
    BOOL canInspectOffer = [capabilities[@"should_offer"] boolValue] && controllerLoaded;
    BOOL canShare = [capabilities[@"share"] boolValue] && controller != nil;
    BOOL hasPersonalNickname = controllerLoaded
        && [controller respondsToSelector:@selector(personalNickname)]
        && ((id (*)(id, SEL))objc_msgSend)(controller, @selector(personalNickname)) != nil;
    id shouldOffer = [NSNull null];
    if (canInspectOffer) {
        @try {
            BOOL offer = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                controller, @selector(shouldOfferNicknameSharingForChat:), chat);
            shouldOffer = @(offer);
        } @catch (NSException *exception) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Name & Photo status failed: %@",
                                           exception.reason ?: @"unknown exception"]);
        }
    }

    NSString *shareSelector = nicknameSharingMutationSelectorName(nnClass);
    BOOL available = canShare && hasPersonalNickname && participants.count > 0
        && senderHandleID.length > 0;
    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"available": @(available),
        @"can_inspect_offer": @(canInspectOffer),
        @"can_share": @(canShare),
        @"personal_nickname_loaded": @(controllerLoaded),
        @"has_personal_nickname": @(hasPersonalNickname),
        @"should_offer": shouldOffer,
        @"participant_count": @(participants.count),
        @"from_handle_available": @(senderHandleID.length > 0),
        @"from_handle_source": senderSource ?: [NSNull null],
        @"share_selector": shareSelector ?: [NSNull null],
        @"force_supported": @(canShare)
    });
}

static NSDictionary *handleShareNickname(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return errorResponse(requestId, @"Missing chatGuid");
    }
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Name & Photo sharing requires an iMessage chat");
    }

    NSArray *participants = [chat respondsToSelector:@selector(participants)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(participants))
        : nil;
    if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) {
        return errorResponse(requestId, @"Chat has no participants to share with");
    }

    Class nnClass = NSClassFromString(@"IMNicknameController");
    NSString *selectorName = nicknameSharingMutationSelectorName(nnClass);
    if (!selectorName) return errorResponse(requestId, @"Name & Photo sharing unavailable");

    @try {
        id controller = sharedNicknameController();
        if (!controller) return errorResponse(requestId, @"IMNicknameController unavailable");
        SEL selector = NSSelectorFromString(selectorName);
        if (![controller respondsToSelector:selector]) {
            return errorResponse(requestId, @"Name & Photo sharing selector unavailable");
        }
        if (!waitForNicknameControllerLoad(controller, 2.0)) {
            return errorResponse(requestId,
                @"Personal Name & Photo is still loading; retry the request");
        }
        if (![controller respondsToSelector:@selector(personalNickname)]
            || ((id (*)(id, SEL))objc_msgSend)(controller,
                                               @selector(personalNickname)) == nil) {
            return errorResponse(requestId,
                @"No personal Name & Photo is configured in Messages");
        }

        BOOL forceSend = YES;
        NSString *senderSource = nil;
        NSString *senderHandleID = nicknameSenderHandleID(chat, &senderSource);
        if (senderHandleID.length == 0) {
            return errorResponse(requestId, @"Could not resolve the chat's local sending handle");
        }
        // Explicit share requests must send even when the handles are already
        // allow-listed; the private API otherwise only updates policy state.
        // IMCore forwards fromHandle: unchanged as a local NSString handle ID;
        // only the participants array contains IMHandle objects.
        ((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(
            controller, selector, participants, chat, senderHandleID, forceSend);

        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"requested": @YES,
            @"participant_count": @(participants.count),
            @"share_selector": selectorName,
            @"force_send": @(forceSend),
            @"from_handle_source": senderSource ?: [NSNull null]
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Name & Photo sharing failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }
}

