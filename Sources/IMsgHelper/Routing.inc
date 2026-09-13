#pragma mark - Command Router

/// Dispatch an action by name, returning a legacy-envelope NSDictionary. Used
/// by both the v1 single-file IPC path and (after key-stripping) the v2 path.
static NSDictionary* dispatchAction(NSInteger legacyId, NSString *action,
                                    NSDictionary *params) {
    if ([action isEqualToString:@"typing"]) {
        return handleTyping(legacyId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(legacyId, params);
    } else if ([action isEqualToString:@"status"] ||
               [action isEqualToString:@"bridge-status"]) {
        return handleStatus(legacyId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(legacyId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(legacyId, @{@"pong": @YES});
    }
    // v2 actions
    if ([action isEqualToString:@"send-message"]) {
        if (params[@"richLinkPreview"] || params[@"richLinkURL"]) {
            return errorResponse(legacyId, @"Use send-rich-link for URL previews");
        }
        return handleSendMessage(legacyId, params);
    }
    if ([action isEqualToString:@"send-rich-link"]) {
        if (![params[@"richLinkPreview"] isKindOfClass:[NSDictionary class]]) {
            return errorResponse(legacyId, @"Missing rich-link descriptor");
        }
        return handleSendMessage(legacyId, params);
    }
    if ([action isEqualToString:@"send-multipart"]) return handleSendMultipart(legacyId, params);
    if ([action isEqualToString:@"send-attachment"]) return handleSendAttachment(legacyId, params);
    if ([action isEqualToString:@"send-sticker"]) return handleSendSticker(legacyId, params);
    if ([action isEqualToString:@"send-poll"]) return handleSendPoll(legacyId, params);
    if ([action isEqualToString:@"send-poll-vote"]) return handleSendPollVote(legacyId, params);
    if ([action isEqualToString:@"send-poll-unvote"]) return handleSendPollUnvote(legacyId, params);
    if ([action isEqualToString:@"send-reaction"]) return handleSendReaction(legacyId, params);
    if ([action isEqualToString:@"notify-anyways"]) return handleNotifyAnyways(legacyId, params);
    if ([action isEqualToString:@"edit-message"]) return handleEditMessage(legacyId, params);
    if ([action isEqualToString:@"unsend-message"]) return handleUnsendMessage(legacyId, params);
    if ([action isEqualToString:@"delete-message"]) return handleDeleteMessage(legacyId, params);
    if ([action isEqualToString:@"start-typing"]) return handleStartTyping(legacyId, params);
    if ([action isEqualToString:@"stop-typing"]) return handleStopTyping(legacyId, params);
    if ([action isEqualToString:@"check-typing-status"]) return handleCheckTypingStatus(legacyId, params);
    if ([action isEqualToString:@"mark-chat-read"]) return handleMarkChatRead(legacyId, params);
    if ([action isEqualToString:@"mark-chat-unread"]) return handleMarkChatUnread(legacyId, params);
    if ([action isEqualToString:@"add-participant"]) return handleAddParticipant(legacyId, params);
    if ([action isEqualToString:@"remove-participant"]) return handleRemoveParticipant(legacyId, params);
    if ([action isEqualToString:@"set-display-name"]) return handleSetDisplayName(legacyId, params);
    if ([action isEqualToString:@"update-group-photo"]) return handleUpdateGroupPhoto(legacyId, params);
    if ([action isEqualToString:@"leave-chat"]) return handleLeaveChat(legacyId, params);
    if ([action isEqualToString:@"delete-chat"]) return handleDeleteChat(legacyId, params);
    if ([action isEqualToString:@"create-chat"]) return handleCreateChat(legacyId, params);
    if ([action isEqualToString:@"search-messages"]) return handleSearchMessages(legacyId, params);
    if ([action isEqualToString:@"get-account-info"]) return handleGetAccountInfo(legacyId, params);
    if ([action isEqualToString:@"get-nickname-info"]) return handleGetNicknameInfo(legacyId, params);
    if ([action isEqualToString:@"should-offer-nickname-sharing"])
        return handleShouldOfferNicknameSharing(legacyId, params);
    if ([action isEqualToString:@"share-nickname"])
        return handleShareNickname(legacyId, params);
    if ([action isEqualToString:@"check-imessage-availability"])
        return handleCheckIMessageAvailability(legacyId, params);
    if ([action isEqualToString:@"download-purged-attachment"])
        return handleDownloadPurgedAttachment(legacyId, params);
    return errorResponse(legacyId,
        [NSString stringWithFormat:@"Unknown action: %@", action]);
}

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-bridge] Processing command: %@ (id=%ld)", action, (long)requestId);
    return dispatchAction(requestId, action, params);
}

/// Process a v2 envelope: re-route to the shared dispatcher, then strip the
/// legacy envelope keys and re-wrap with the v2 shape.
static NSDictionary* processV2Envelope(NSDictionary *envelope) {
    NSString *uuid = envelope[@"id"];
    if (![uuid isKindOfClass:[NSString class]]) uuid = @"";
    NSString *action = envelope[@"action"];
    NSDictionary *params = envelope[@"params"] ?: @{};
    if (![action isKindOfClass:[NSString class]] || action.length == 0) {
        return errorResponseV2(uuid, @"Missing action");
    }

    NSLog(@"[imsg-bridge v2] action=%@ id=%@", action, uuid);

    NSDictionary *legacy = dispatchAction(0, action, params);
    if (![legacy isKindOfClass:[NSDictionary class]]) {
        return errorResponseV2(uuid, @"Internal: handler returned non-dictionary");
    }

    BOOL ok = [legacy[@"success"] boolValue];
    if (!ok) {
        NSString *errMsg = legacy[@"error"];
        NSString *disposition = legacy[@"delivery_disposition"];
        return disposition.length
            ? errorResponseV2WithDisposition(uuid, errMsg ?: @"Unknown error", disposition)
            : errorResponseV2(uuid, errMsg ?: @"Unknown error");
    }

    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:legacy];
    [data removeObjectForKey:@"id"];
    [data removeObjectForKey:@"success"];
    [data removeObjectForKey:@"error"];
    [data removeObjectForKey:@"timestamp"];
    return successResponseV2(uuid, data);
}

