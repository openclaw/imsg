#pragma mark - Chat Management Handlers (v2)

static NSDictionary *handleStartTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    debugLog(@"handleStartTyping: chatGuid=%@", chatGuid);
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        debugLog(@"handleStartTyping: chat not found");
        return errorResponse(requestId, @"Chat not found");
    }
    BOOL beforeT = readLocalUserIsTyping(chat);
    @try { [chat setLocalUserIsTyping:YES]; }
    @catch (NSException *ex) {
        debugLog(@"handleStartTyping: exception=%@", ex.reason);
        return errorResponse(requestId, ex.reason ?: @"failed");
    }
    BOOL afterT = readLocalUserIsTyping(chat);
    debugLog(@"handleStartTyping: setLocalUserIsTyping:YES beforeIsTyping=%d afterIsTyping=%d "
             @"chatClass=%@", beforeT, afterT, NSStringFromClass([chat class]));
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @YES});
}

static NSDictionary *handleStopTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    debugLog(@"handleStopTyping: chatGuid=%@", chatGuid);
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat setLocalUserIsTyping:NO]; }
    @catch (NSException *ex) {
        debugLog(@"handleStopTyping: exception=%@", ex.reason);
        return errorResponse(requestId, ex.reason ?: @"failed");
    }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @NO});
}

static NSDictionary *handleCheckTypingStatus(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    BOOL typing = readLocalUserIsTyping(chat);
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @(typing)});
}

static NSDictionary *handleMarkChatRead(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *handle = params[@"handle"];
    id chat = nil;
    if (chatGuid.length) chat = resolveChatByGuid(chatGuid);
    if (!chat && handle.length) chat = findChat(handle);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat performSelector:@selector(markAllMessagesAsRead)]; }
    @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid ?: @"", @"marked_as_read": @YES});
}

static NSDictionary *handleMarkChatUnread(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        // BB-verified macOS 11+ path: `markLastMessageAsUnread` is the
        // daemon-aware selector that flips read=0 in chat.db AND triggers
        // UI badge refresh. The `setUnreadCount:` we used previously only
        // mutated a local KVO counter that didn't persist.
        if ([chat respondsToSelector:@selector(markLastMessageAsUnread)]) {
            [chat performSelector:@selector(markLastMessageAsUnread)];
        } else {
            return errorResponse(requestId, @"markLastMessageAsUnread not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"marked_as_unread": @YES});
}

static NSDictionary *handleAddParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    // Match chat-create's fallback-capable iMessage handle lookup.
    id handle = vendIMHandle(hr, address, @"iMessage", YES, YES);
    if (!handle) return errorResponse(requestId, @"Could not vend handle");
    NSString *availabilityError = iMessageAvailabilityError(handle, address);
    if (availabilityError) return errorResponse(requestId, availabilityError);

    @try {
        // macOS 26 renamed this selector; retain the older spelling as fallback.
        SEL sel = 0;
        for (NSString *name in @[@"inviteParticipants:reason:",
                                 @"inviteParticipantsToiMessageChat:reason:"]) {
            SEL cand = NSSelectorFromString(name);
            if ([chat respondsToSelector:cand]) { sel = cand; break; }
        }
        if (!sel) {
            return errorResponse(requestId, @"no participant-invite selector available on this IMChat");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[handle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"added": @YES});
}

static NSDictionary *handleRemoveParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    // Find the matching participant handle on the chat itself.
    id targetHandle = nil;
    if ([chat respondsToSelector:@selector(participants)]) {
        for (id h in [chat performSelector:@selector(participants)]) {
            if ([h respondsToSelector:@selector(ID)]
                && [[h performSelector:@selector(ID)] isEqualToString:address]) {
                targetHandle = h; break;
            }
        }
    }
    if (!targetHandle) return errorResponse(requestId, @"Participant not found on chat");

    @try {
        // macOS 26 renamed this selector; retain the older spelling as fallback.
        SEL sel = 0;
        for (NSString *name in @[@"removeParticipants:reason:",
                                 @"removeParticipantsFromiMessageChat:reason:"]) {
            SEL cand = NSSelectorFromString(name);
            if ([chat respondsToSelector:cand]) { sel = cand; break; }
        }
        if (!sel) {
            return errorResponse(requestId, @"no participant-remove selector available on this IMChat");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[targetHandle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"removed": @YES});
}

static NSDictionary *handleSetDisplayName(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *newName = params[@"newName"] ?: params[@"name"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        // BB-verified: `_setDisplayName:` (underscore-prefixed) is the
        // private mutator that posts the IDS update so other chat members
        // see the rename. The public `setDisplayName:` we used before was
        // just the KVO setter — it changed the local property without
        // propagating, so renames were sender-only.
        if ([chat respondsToSelector:@selector(_setDisplayName:)]) {
            [chat performSelector:@selector(_setDisplayName:) withObject:newName ?: @""];
        } else {
            return errorResponse(requestId, @"_setDisplayName: not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"name": newName ?: @""});
}

static NSDictionary *handleUpdateGroupPhoto(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    @try {
        // BB-verified: group-photo updates go through the file-transfer
        // pipeline, not raw bytes. Stage the photo via prepareOutgoingTransfer
        // (so it lives in IMD's attachments tree), then call
        // sendGroupPhotoUpdate: with the transfer guid. Passing nil/empty
        // file path clears the photo.
        SEL sel = @selector(sendGroupPhotoUpdate:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"sendGroupPhotoUpdate: not available");
        }
        if (filePath.length == 0) {
            [chat performSelector:sel withObject:nil];
            return successResponse(requestId,
                @{@"chatGuid": chatGuid, @"cleared": @YES, @"size": @0});
        }
        if (pathHasSymlinkComponent(filePath)) {
            return errorResponse(requestId, @"Group photo path traverses a symlink");
        }
        NSURL *fileURL = [NSURL fileURLWithPath:filePath];
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, [fileURL lastPathComponent], chatGuid,
            IMsgOutgoingTransferKindAttachment, nil, NULL, &prepErr);
        if (!transfer || ![transfer guid].length) {
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not prepare group-photo transfer");
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register group-photo transfer");
        }
        [chat performSelector:sel withObject:[transfer guid]];
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"cleared": @NO,
            @"transferGuid": [transfer guid]
        });
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
}

static NSDictionary *handleLeaveChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        if ([chat respondsToSelector:@selector(leaveChat)]) {
            [chat performSelector:@selector(leaveChat)];
        } else {
            return errorResponse(requestId, @"leaveChat not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"left": @YES});
}

static NSDictionary *handleDeleteChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    SEL deleteSelector = NSSelectorFromString(@"deleteChat:");
    SEL removeSelector = NSSelectorFromString(@"_chat_remove:");
    SEL selectedSelector = NULL;
    if ([reg respondsToSelector:deleteSelector]) {
        selectedSelector = deleteSelector;
    } else if ([reg respondsToSelector:removeSelector]) {
        // macOS 26 removed deleteChat:, while Messages still uses the
        // daemon-aware registry removal path exposed as _chat_remove:.
        selectedSelector = removeSelector;
    }
    if (!reg || selectedSelector == NULL) {
        return errorResponse(requestId,
            @"Chat deletion is unavailable (deleteChat: and _chat_remove: missing)");
    }
    @try {
        [reg performSelector:selectedSelector withObject:chat];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"deleted": @YES,
        @"method": NSStringFromSelector(selectedSelector)
    });
}

/// `create-chat`: vend handles for each address, ask the registry for a chat
/// instance, optionally set the display name, optionally send an initial
/// message. Returns the new chat's guid.
static NSDictionary *handleCreateChat(NSInteger requestId, NSDictionary *params) {
    NSArray *addresses = params[@"addresses"];
    NSString *initialMessage = params[@"message"];
    NSString *displayName = params[@"displayName"] ?: params[@"name"];
    NSString *requestedService = params[@"service"] ?: @"iMessage";
    NSString *preferredService = @"iMessage";
    NSString *responseService = @"iMessage";

    if (![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing addresses array");
    }
    if ([requestedService caseInsensitiveCompare:@"iMessage"] == NSOrderedSame) {
        preferredService = @"iMessage";
        responseService = @"iMessage";
    } else if ([requestedService caseInsensitiveCompare:@"auto"] == NSOrderedSame) {
        preferredService = @"iMessage";
        responseService = @"iMessage";
    } else if ([requestedService caseInsensitiveCompare:@"sms"] == NSOrderedSame) {
        preferredService = @"SMS";
        responseService = @"SMS";
    } else {
        return errorResponse(requestId, [NSString stringWithFormat:
            @"Unsupported chat-create service: %@", requestedService]);
    }

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *addr in addresses) {
        if (![addr isKindOfClass:[NSString class]] || addr.length == 0) {
            return errorResponse(requestId, @"Each address must be a non-empty phone number or email");
        }
        id h = vendIMHandle(hr, addr, preferredService, NO, YES);
        if (!h) return errorResponse(requestId, [NSString stringWithFormat:
            @"Could not create %@ handle for %@; check that the account is signed in to Messages",
            preferredService, addr]);
        if ([preferredService isEqualToString:@"iMessage"]) {
            NSString *availabilityError = iMessageAvailabilityError(h, addr);
            if (availabilityError) return errorResponse(requestId, availabilityError);
        }
        [handles addObject:h];
    }

    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    id chat = nil;
    if (handles.count == 1 && [reg respondsToSelector:@selector(chatForIMHandle:)]) {
        chat = [reg performSelector:@selector(chatForIMHandle:) withObject:handles.firstObject];
    } else if ([reg respondsToSelector:@selector(chatForIMHandles:)]) {
        chat = [reg performSelector:@selector(chatForIMHandles:) withObject:handles];
    }
    if (!chat) return errorResponse(requestId, @"Registry could not produce chat");

    if (displayName.length && [chat respondsToSelector:@selector(_setDisplayName:)]) {
        @try { [chat performSelector:@selector(_setDisplayName:) withObject:displayName]; }
        @catch (__unused NSException *ex) {}
    }

    NSString *messageGuid = nil;
    if (initialMessage.length) {
        NSAttributedString *body = buildPlainAttributed(initialMessage, 0);
        @try {
            id imMessage = buildIMMessage(body, nil, nil, nil, nil,
                                          nil, 0,
                                          NSMakeRange(0, body.length),
                                          nil, @[], NO, NO, nil);
            if (imMessage) {
                dispatchIMMessageInChat(chat, imMessage, nil, nil);
                messageGuid = outgoingMessageGuid(imMessage);
            }
        } @catch (__unused NSException *ex) {}
    }

    NSString *guid = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : @"";
    NSString *observedService = serviceNameForChat(chat, guid);
    if (observedService.length) responseService = observedService;
    return successResponse(requestId, @{
        @"chatGuid": guid ?: @"",
        @"service": responseService,
        @"messageGuid": messageGuid ?: @"",
        @"participants": addresses
    });
}

