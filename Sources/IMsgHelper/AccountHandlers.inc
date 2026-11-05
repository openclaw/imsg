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

static BOOL protocolDeclaresInstanceMethod(NSString *protocolName, SEL selector) {
    Protocol *protocol = NSProtocolFromString(protocolName);
    if (!protocol) return NO;
    return protocol_getMethodDescription(protocol, selector, YES, YES).name != NULL
        || protocol_getMethodDescription(protocol, selector, NO, YES).name != NULL;
}

static BOOL personalNicknameSetAvailable(void) {
    Class daemonClass = NSClassFromString(@"IMDaemonController");
    return [NSClassFromString(@"IMNickname")
               instancesRespondToSelector:@selector(initWithFirstName:lastName:avatar:pronouns:)]
        && [NSClassFromString(@"IMNicknameAvatarImage")
               instancesRespondToSelector:@selector(initWithImageName:imageFilePath:sensitivityAnalysis:)]
        && [NSClassFromString(@"IMMeCardSharingStateController")
               instancesRespondToSelector:@selector(setSharingEnabled:)]
        && daemonClass && [(id)daemonClass respondsToSelector:@selector(sharedController)]
        && [daemonClass instancesRespondToSelector:@selector(remoteDaemon)]
        && protocolDeclaresInstanceMethod(@"IMDaemonAnyProtocol",
                                          @selector(setNewPersonalNickname:));
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
        @"set": @(hasSharedInstance && personalNicknameSetAvailable()),
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

static NSString *nicknameStringProperty(id object, SEL selector) {
    id value = safelyReadObjectSelector(object, selector);
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static NSNumber *nicknameBoolProperty(id object, SEL selector) {
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
    } @catch (__unused NSException *exception) {
        return nil;
    }
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
        if (nickname) {
            info[@"description"] = [nickname description] ?: @"";
            info[@"first_name"] = nicknameStringProperty(nickname, @selector(firstName));
            info[@"last_name"] = nicknameStringProperty(nickname, @selector(lastName));
            info[@"display_name"] = nicknameStringProperty(nickname, @selector(displayName));

            id avatar = safelyReadObjectSelector(nickname, @selector(avatar));
            NSString *avatarPath = nicknameStringProperty(avatar, @selector(imageFilePath));
            if (avatarPath && [nicknameBoolProperty(avatar, @selector(imageExists)) boolValue]) {
                info[@"avatar_path"] = avatarPath;
                info[@"avatar_is_sensitive"] =
                    nicknameBoolProperty(avatar, @selector(contentIsSensitive));
            }
        }
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

/// Sets the account's personal Name & Photo, the record that Name & Photo
/// Sharing sends to chats, and optionally turns sharing on or off. Messages
/// asks imagent to store the record through IMDaemonController's remote daemon;
/// IMNicknameController's updatePersonalNickname: is only the daemon's echo
/// back to Messages and stores nothing on its own.
///
/// `photoPath` must be staged under ~/Library/Messages/Attachments/imsg.
/// IMTransferAgent uploads the photo and moves it into Messages' nickname
/// cache, and its sandbox cannot read a file inside the Messages container.
/// The answer waits for imagent's echo so `stored` reports what Messages now
/// holds rather than that a request was sent.
///
/// A receiving device's BlastDoor validates the record before showing it, and
/// a value Messages itself never writes fails that validation. Records Messages
/// writes name the avatar image `NickNameImage` and leave out an empty last name.
static NSDictionary *handleSetPersonalNickname(NSInteger requestId, NSDictionary *params) {
    NSString *firstName = params[@"firstName"];
    if (![firstName isKindOfClass:[NSString class]] || firstName.length == 0) {
        return errorResponse(requestId, @"Missing firstName");
    }
    if ((params[@"lastName"] && ![params[@"lastName"] isKindOfClass:[NSString class]])
        || (params[@"photoPath"] && (![params[@"photoPath"] isKindOfClass:[NSString class]]
                                      || ![params[@"photoPath"] length]))) {
        return errorResponse(requestId, @"lastName and photoPath must be strings; photoPath must not be empty");
    }
    NSString *lastName = [params[@"lastName"] isKindOfClass:[NSString class]]
            && [params[@"lastName"] length] > 0
        ? params[@"lastName"]
        : nil;
    NSString *photoPath = [params[@"photoPath"] isKindOfClass:[NSString class]]
        ? params[@"photoPath"]
        : nil;
    id sharing = params[@"sharingEnabled"];
    if (sharing && (![sharing isKindOfClass:[NSNumber class]]
                    || CFGetTypeID((__bridge CFTypeRef)sharing) != CFBooleanGetTypeID())) {
        return errorResponse(requestId, @"sharingEnabled must be a boolean");
    }
    if (!personalNicknameSetAvailable()) {
        return errorResponse(requestId, @"Setting Name & Photo is unavailable");
    }
    if (photoPath.length > 0) {
        if (!richLinkPathIsTrusted(photoPath)) {
            return errorResponse(requestId,
                @"photoPath must be staged under ~/Library/Messages/Attachments/imsg");
        }
        if (![[NSFileManager defaultManager] isReadableFileAtPath:photoPath]) {
            return errorResponse(requestId, @"Could not read photoPath");
        }
    }

    @try {
        id controller = sharedNicknameController();
        if (!controller) return errorResponse(requestId, @"IMNicknameController unavailable");
        if (!waitForNicknameControllerLoad(controller, 2.0)) {
            return errorResponse(requestId,
                @"Personal Name & Photo is still loading; retry the request");
        }

        id avatar = nil;
        if (photoPath.length > 0) {
            avatar = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                [NSClassFromString(@"IMNicknameAvatarImage") alloc],
                @selector(initWithImageName:imageFilePath:sensitivityAnalysis:),
                @"NickNameImage", photoPath, nil);
            if (!avatar) return errorResponse(requestId, @"Could not build the avatar");
        }
        id nickname = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            [NSClassFromString(@"IMNickname") alloc],
            @selector(initWithFirstName:lastName:avatar:pronouns:),
            firstName, lastName, avatar, nil);
        if (!nickname) return errorResponse(requestId, @"Could not build the nickname");

        id daemon = ((id (*)(id, SEL))objc_msgSend)(
            NSClassFromString(@"IMDaemonController"), @selector(sharedController));
        id remote = ((id (*)(id, SEL))objc_msgSend)(daemon, @selector(remoteDaemon));
        if (!remote) return errorResponse(requestId, @"Messages has no daemon connection");

        id previous = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(personalNickname));
        ((void (*)(id, SEL, id))objc_msgSend)(remote, @selector(setNewPersonalNickname:), nickname);
        if (sharing) {
            id state = [[NSClassFromString(@"IMMeCardSharingStateController") alloc] init];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(state, @selector(setSharingEnabled:),
                                                    [sharing boolValue]);
        }

        // imagent stores the record, uploads the photo, and echoes the new
        // personal nickname to every client. A different object carrying the
        // requested first name is that echo.
        id personal = previous;
        BOOL stored = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!stored && [deadline timeIntervalSinceNow] > 0) {
            NSDate *nextCheck = [NSDate dateWithTimeIntervalSinceNow:0.1];
            if ([NSThread isMainThread]) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:nextCheck];
            } else {
                [NSThread sleepForTimeInterval:0.1];
            }
            personal = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(personalNickname));
            stored = personal != previous
                && [nicknameStringProperty(personal, @selector(firstName)) isEqualToString:firstName]
                && [(nicknameStringProperty(personal, @selector(lastName)) ?: @"")
                        isEqualToString:lastName ?: @""];
        }

        BOOL hasPhoto = avatar != nil;
        NSMutableDictionary *result = [@{
            @"requested": @YES,
            @"stored": @(stored),
            @"has_photo": @(hasPhoto)
        } mutableCopy];
        if (sharing) result[@"sharing_enabled"] = @([sharing boolValue]);
        if (stored) {
            result[@"first_name"] = nicknameStringProperty(personal, @selector(firstName)) ?: @"";
            NSString *storedLastName = nicknameStringProperty(personal, @selector(lastName));
            if (storedLastName.length > 0) result[@"last_name"] = storedLastName;
        }
        return successResponse(requestId, result);
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Setting Name & Photo failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }
}
