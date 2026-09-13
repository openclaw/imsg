#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];
    debugLog(@"handleTyping: enter handle=%@ state=%@ params=%@", handle, state, params);

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        debugLog(@"handleTyping: chat not found for %@", handle);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Gather diagnostic info
        NSString *chatGUID = @"unknown";
        NSString *chatIdent = @"unknown";
        NSString *chatClass = NSStringFromClass([chat class]);
        BOOL supportsTyping = YES;

        if ([chat respondsToSelector:@selector(guid)]) {
            chatGUID = [chat performSelector:@selector(guid)] ?: @"nil";
        }
        if ([chat respondsToSelector:@selector(chatIdentifier)]) {
            chatIdent = [chat performSelector:@selector(chatIdentifier)] ?: @"nil";
        }

        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
        }

        BOOL isCurrentlyTyping = readLocalUserIsTyping(chat);

        id account = nil;
        NSString *acctService = @"nil";
        BOOL acctActive = NO;
        BOOL acctConnected = NO;
        if ([chat respondsToSelector:@selector(account)]) {
            account = [chat performSelector:@selector(account)];
            if ([account respondsToSelector:@selector(serviceName)]) {
                acctService = [account performSelector:@selector(serviceName)] ?: @"nil";
            }
            if ([account respondsToSelector:@selector(isActive)]) {
                acctActive = ((BOOL (*)(id, SEL))objc_msgSend)(account, @selector(isActive));
            }
            acctConnected = readAccountConnected(account);
        }

        debugLog(@"handleTyping: chat class=%@ guid=%@ ident=%@ supportsTyping=%d alreadyTyping=%d "
                 @"acctService=%@ acctActive=%d acctConnected=%d target=%d",
                 chatClass, chatGUID, chatIdent, supportsTyping, isCurrentlyTyping,
                 acctService, acctActive, acctConnected, typing);

        NSLog(@"[imsg-bridge] Chat found: class=%@, guid=%@, identifier=%@, supportsTyping=%@",
              chatClass, chatGUID, chatIdent, supportsTyping ? @"YES" : @"NO");

        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            if (!sig) {
                return errorResponse(requestId,
                    @"Could not get method signature for setLocalUserIsTyping:");
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            BOOL afterTyping = readLocalUserIsTyping(chat);
            // Real send oracle: -[IMChat latestTypingIndicatorSendTimeInterval] is
            // the timestamp of the last typing indicator actually dispatched to the
            // remote. If it advances across the set, the indicator really went out —
            // unlike the local typing flag, which can be transient.
            double sendTs = -1;
            if ([chat respondsToSelector:@selector(latestTypingIndicatorSendTimeInterval)]) {
                sendTs = ((double (*)(id, SEL))objc_msgSend)(
                    chat, @selector(latestTypingIndicatorSendTimeInterval));
            }
            debugLog(@"handleTyping: setLocalUserIsTyping:%d returned, localUserIsTyping after=%d "
                     @"latestTypingIndicatorSendTimeInterval=%.3f",
                     typing, afterTyping, sendTs);

            NSLog(@"[imsg-bridge] Called setLocalUserIsTyping:%@ for %@",
                  typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing)
            });
        }

        debugLog(@"handleTyping: setLocalUserIsTyping: not available on chat class=%@", chatClass);
        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        debugLog(@"handleTyping: exception=%@", exception.reason);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    debugLog(@"handleRead: enter handle=%@ params=%@", handle, params);

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        debugLog(@"handleRead: chat not found for %@", handle);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    NSString *chatClass = NSStringFromClass([chat class]);
    NSUInteger unreadBefore = 0;
    BOOL hadUnread = NO;
    if ([chat respondsToSelector:@selector(unreadMessageCount)]) {
        unreadBefore = ((NSUInteger (*)(id, SEL))objc_msgSend)(chat, @selector(unreadMessageCount));
    }
    if ([chat respondsToSelector:@selector(hasUnreadMessages)]) {
        hadUnread = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(hasUnreadMessages));
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        debugLog(@"handleRead: chat class=%@ unreadBefore=%lu hasUnread=%d responds=%d",
                 chatClass, (unsigned long)unreadBefore, hadUnread,
                 [chat respondsToSelector:readSel]);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSUInteger unreadAfter = 0;
            BOOL hasUnreadAfter = NO;
            if ([chat respondsToSelector:@selector(unreadMessageCount)]) {
                unreadAfter = ((NSUInteger (*)(id, SEL))objc_msgSend)(chat, @selector(unreadMessageCount));
            }
            if ([chat respondsToSelector:@selector(hasUnreadMessages)]) {
                hasUnreadAfter = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(hasUnreadMessages));
            }
            debugLog(@"handleRead: markAllMessagesAsRead returned, unreadAfter=%lu hasUnreadAfter=%d",
                     (unsigned long)unreadAfter, hasUnreadAfter);
            NSLog(@"[imsg-bridge] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        debugLog(@"handleRead: exception=%@", exception.reason);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

static BOOL stickerAttachmentMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    return [messageClass instancesRespondToSelector:NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:")]
        || [messageClass instancesRespondToSelector:NSSelectorFromString(
            @"initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:")];
}

static BOOL stickerAssociatedMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    return [messageClass instancesRespondToSelector:NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:")]
        || [messageClass instancesRespondToSelector:NSSelectorFromString(
            @"initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:")];
}

static BOOL plainMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    Class itemClass = NSClassFromString(@"IMMessageItem");
    BOOL itemPath = itemClass && messageClass
        && [itemClass instancesRespondToSelector:NSSelectorFromString(
            @"initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:")]
        && [messageClass respondsToSelector:NSSelectorFromString(
            @"messageFromIMMessageItem:sender:subject:")];
    return itemPath || stickerAttachmentMessageInitializerAvailable()
        || [messageClass instancesRespondToSelector:@selector(initWithText:flags:)];
}

static BOOL clientMessageGuidInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    Class itemClass = NSClassFromString(@"IMMessageItem");
    BOOL itemPath = itemClass && messageClass
        && [itemClass instancesRespondToSelector:NSSelectorFromString(
            @"initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:")]
        && [messageClass respondsToSelector:NSSelectorFromString(
            @"messageFromIMMessageItem:sender:subject:")];
    return itemPath || stickerAttachmentMessageInitializerAvailable();
}

static BOOL stickerTransferSelectorsAvailable(void) {
    Class transferClass = NSClassFromString(@"IMFileTransfer");
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    return [transferClass instancesRespondToSelector:NSSelectorFromString(@"setIsSticker:")]
        && [transferClass instancesRespondToSelector:NSSelectorFromString(@"setStickerUserInfo:")]
        && [transferClass instancesRespondToSelector:NSSelectorFromString(@"setAttributionInfo:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(
            @"guidForNewOutgoingTransferWithLocalURL:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(@"transferForGUID:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(
            @"registerTransferWithDaemon:")];
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    id registry = registryClass && [registryClass respondsToSelector:@selector(sharedInstance)]
        ? [registryClass performSelector:@selector(sharedInstance)]
        : nil;
    BOOL hasRegistry = (registry != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    NSDictionary *nicknameSelectors = nicknameSharingSelectorStatus();
    Class stickerTransferClass = NSClassFromString(@"IMFileTransfer");
    Class transferCenterClass = NSClassFromString(@"IMFileTransferCenter");
    Class chatClass = NSClassFromString(@"IMChat");
    Class handleRegistrarClass = NSClassFromString(@"IMHandleRegistrar");
    Class idQueryClass = NSClassFromString(@"IDSIDQueryController");
    Class accountControllerClass = NSClassFromString(@"IMAccountController");
    Class accountClass = NSClassFromString(@"IMAccount");
    Class handleClass = NSClassFromString(@"IMHandle");
    BOOL handleRegistrar = handleRegistrarClass
        && [handleRegistrarClass respondsToSelector:@selector(sharedInstance)]
        && ([handleRegistrarClass instancesRespondToSelector:@selector(IMHandleWithID:)]
            || [handleRegistrarClass instancesRespondToSelector:@selector(getIMHandlesForID:)]);
    BOOL activeSenderHandle = accountControllerClass && accountClass && handleClass
        && [accountControllerClass respondsToSelector:@selector(sharedInstance)]
        && [accountControllerClass instancesRespondToSelector:@selector(activeIMessageAccount)]
        && [accountClass instancesRespondToSelector:@selector(loginIMHandle)]
        && [handleClass instancesRespondToSelector:@selector(ID)];
    BOOL chatSend = [chatClass instancesRespondToSelector:@selector(sendMessage:)]
        && plainMessageInitializerAvailable();
    BOOL clientMessageGuid = [chatClass instancesRespondToSelector:@selector(sendMessage:)]
        && clientMessageGuidInitializerAvailable();
    BOOL reactionSend = [chatClass instancesRespondToSelector:@selector(sendMessage:)]
        && stickerAssociatedMessageInitializerAvailable();
    BOOL typingAvailable = hasRegistry
        && [chatClass instancesRespondToSelector:@selector(setLocalUserIsTyping:)];
    BOOL readAvailable = hasRegistry
        && [chatClass instancesRespondToSelector:@selector(markAllMessagesAsRead)];
    BOOL stickerSetIsSticker = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setIsSticker:")];
    BOOL stickerSetUserInfo = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setStickerUserInfo:")];
    BOOL stickerSetAttribution = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setAttributionInfo:")];
    BOOL stickerTransferCenter =
        [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"guidForNewOutgoingTransferWithLocalURL:")]
        && [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"transferForGUID:")]
        && [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"registerTransferWithDaemon:")];
    BOOL createChat = handleRegistrar && hasRegistry
        && ([registryClass instancesRespondToSelector:@selector(chatForIMHandle:)]
            || [registryClass instancesRespondToSelector:@selector(chatForIMHandles:)]);
    BOOL addParticipant = handleRegistrar
        && ([chatClass instancesRespondToSelector:NSSelectorFromString(
                @"inviteParticipants:reason:")]
            || [chatClass instancesRespondToSelector:NSSelectorFromString(
                @"inviteParticipantsToiMessageChat:reason:")]);
    BOOL removeParticipant = [chatClass instancesRespondToSelector:@selector(participants)]
        && ([chatClass instancesRespondToSelector:NSSelectorFromString(
                @"removeParticipants:reason:")]
            || [chatClass instancesRespondToSelector:NSSelectorFromString(
                @"removeParticipantsFromiMessageChat:reason:")]);
    BOOL handleCheck = idQueryClass
        && ([idQueryClass respondsToSelector:@selector(sharedInstance)]
            || [idQueryClass respondsToSelector:@selector(sharedController)])
        && ([idQueryClass instancesRespondToSelector:
                @selector(_currentIDStatusForDestination:service:listenerID:)]
            || [idQueryClass instancesRespondToSelector:
                @selector(currentIDStatusForDestination:service:)]);
    BOOL stickerReplyTo = [NSClassFromString(@"IMMessage")
        instancesRespondToSelector:NSSelectorFromString(@"setReplyToGUID:")];
    BOOL stickerTargetMembership = [NSClassFromString(@"IMChat")
        instancesRespondToSelector:NSSelectorFromString(@"hasStoredMessageWithGUID:")];
    BOOL stickerTargetLookup = [NSClassFromString(@"IMChatHistoryController")
        instancesRespondToSelector:NSSelectorFromString(
            @"loadMessageWithGUID:completionBlock:")]
        && [NSClassFromString(@"IMMessage")
            instancesRespondToSelector:NSSelectorFromString(@"_imMessageItem")]
        && [NSClassFromString(@"IMMessageItem")
            instancesRespondToSelector:NSSelectorFromString(@"_newChatItems")]
        && [NSClassFromString(@"IMMessagePartChatItem")
            instancesRespondToSelector:NSSelectorFromString(@"index")]
        && [NSClassFromString(@"IMMessagePartChatItem")
            instancesRespondToSelector:NSSelectorFromString(@"messagePartRange")];
    BOOL stickerAttachmentMessage = stickerAttachmentMessageInitializerAvailable();
    BOOL stickerAssociatedMessage = stickerAssociatedMessageInitializerAvailable();
    BOOL attachmentSend = stickerTransferCenter && stickerAttachmentMessage
        && [chatClass instancesRespondToSelector:@selector(sendMessage:)];
    BOOL stickerSend = stickerSetIsSticker && stickerSetUserInfo
        && stickerSetAttribution && attachmentSend;
    NSDictionary *selectors = @{
        @"editMessageItemTranslation": @(gHasEditMessageItemTranslation),
        @"editMessageItem": @(gHasEditMessageItem),
        @"editMessage": @(gHasEditMessage),
        @"retractMessagePart": @(gHasRetractMessagePart),
        @"sendMessageReason": @(gHasSendMessageReason),
        @"sendMessage": @(chatSend),
        @"clientMessageGuid": @(clientMessageGuid),
        @"clientMessageGuidReservation": @(clientMessageGuid),
        @"sendAttachment": @(attachmentSend),
        @"sendMultipart": @(chatSend),
        @"sendReaction": @(reactionSend),
        @"pollPayloadMessage": @(
            [chatClass instancesRespondToSelector:@selector(sendMessage:)]
                && pollPayloadMessageInitializerAvailable()),
        @"pollVoteMessage": @(
            [chatClass instancesRespondToSelector:@selector(sendMessage:)]
                && pollVoteMessageInitializerAvailable() && activeSenderHandle),
        @"typing": @(typingAvailable),
        @"read": @(readAvailable),
        @"createChat": @(createChat),
        @"markChatUnread": @(
            [chatClass instancesRespondToSelector:@selector(markLastMessageAsUnread)]),
        @"deleteMessage": @(
            [chatClass instancesRespondToSelector:@selector(deleteChatItems:)]),
        @"notifyAnyways": @(
            [chatClass instancesRespondToSelector:@selector(markChatItemAsNotifyRecipient:)]),
        @"setDisplayName": @(
            [chatClass instancesRespondToSelector:@selector(_setDisplayName:)]),
        @"updateGroupPhoto": @(
            [chatClass instancesRespondToSelector:@selector(sendGroupPhotoUpdate:)]),
        @"addParticipant": @(addParticipant),
        @"removeParticipant": @(removeParticipant),
        @"leaveChat": @([chatClass instancesRespondToSelector:@selector(leaveChat)]),
        @"checkIMessageAvailability": @(handleCheck),
        @"nicknameLookup": nicknameSelectors[@"nickname_lookup"],
        @"namePhotoShouldOffer": nicknameSelectors[@"should_offer"],
        @"namePhotoShare": nicknameSelectors[@"share"],
        @"stickerSetIsSticker": @(stickerSetIsSticker),
        @"stickerSetUserInfo": @(stickerSetUserInfo),
        @"stickerSetAttribution": @(stickerSetAttribution),
        @"stickerTransferCenter": @(stickerTransferCenter),
        @"stickerReplyTo": @(stickerReplyTo),
        @"stickerTargetMembership": @(stickerTargetMembership),
        @"stickerTargetLookup": @(stickerTargetLookup),
        @"stickerAttachmentMessage": @(stickerAttachmentMessage),
        @"stickerAssociatedMessage": @(stickerAssociatedMessage),
        @"stickerSend": @(stickerSend),
        @"stickerAttach": @(
            stickerSend && stickerTargetMembership && stickerTargetLookup
                && stickerAssociatedMessage),
        @"urlPreviewMessage": @(urlPreviewMessageInitializerAvailable()),
        @"sendRichLinkAction": @YES,
        @"pollUpdateMessage": @(
            [chatClass instancesRespondToSelector:@selector(sendMessage:)]
                && pollVoteMessageInitializerAvailable() && activeSenderHandle),
        @"deleteChat": @(hasRegistry &&
            [registryClass instancesRespondToSelector:NSSelectorFromString(@"deleteChat:")]),
        @"removeChat": @(hasRegistry &&
            [registryClass instancesRespondToSelector:NSSelectorFromString(@"_chat_remove:")])
    };

    return successResponse(requestId, @{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(typingAvailable),
        @"read_available": @(readAvailable),
        @"bridge_version": @2,
        @"v2_ready": @(rpcInboxTimer != nil),
        @"attachment_metadata": @YES,
        @"client_message_guid": @(clientMessageGuid),
        @"selectors": selectors
    });
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

