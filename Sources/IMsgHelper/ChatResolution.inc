#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

static NSDictionary* errorResponseWithDisposition(NSInteger requestId,
                                                   NSString *error,
                                                   NSString *disposition) {
    NSMutableDictionary *response = [errorResponse(requestId, error) mutableCopy];
    if (disposition.length) response[@"delivery_disposition"] = disposition;
    return response;
}

/// The injected helper is the cross-process ownership boundary for tracked
/// sends. Reserve each caller GUID once immediately before dispatch so two RPC
/// children cannot both publish messages with the same identity.
static BOOL reserveTrackedMessageGuid(NSString *guid) {
    if (!guid.length) return NO;
    os_unfair_lock_lock(&trackedMessageGuidLock);
    if (!trackedMessageGuids) trackedMessageGuids = [NSMutableSet set];
    BOOL available = ![trackedMessageGuids containsObject:guid];
    if (available) [trackedMessageGuids addObject:guid];
    os_unfair_lock_unlock(&trackedMessageGuidLock);
    return available;
}

static NSString *serviceNameForChat(IMChat *chat, NSString *chatGuid) {
    NSString *serviceName = nil;
    if ([chat respondsToSelector:@selector(account)]) {
        id account = [chat performSelector:@selector(account)];
        if ([account respondsToSelector:@selector(serviceName)]) {
            serviceName = [account performSelector:@selector(serviceName)];
        }
    }
    if (serviceName.length) return serviceName;
    if ([chatGuid hasPrefix:@"SMS;"]) return @"SMS";
    if ([chatGuid hasPrefix:@"iMessage;"]) return @"iMessage";
    if ([chatGuid hasPrefix:@"iMessageLite;"]) return @"iMessageLite";
    return nil;
}

static NSArray *handlesFromCandidate(id candidate) {
    NSMutableArray *handles = [NSMutableArray array];
    if ([candidate isKindOfClass:[NSArray class]]) {
        [handles addObjectsFromArray:candidate];
    } else if ([candidate isKindOfClass:[NSSet class]]) {
        [handles addObjectsFromArray:[candidate allObjects]];
    } else if (candidate) {
        [handles addObject:candidate];
    }
    return handles;
}

static id handleMatchingService(NSArray *handles, NSString *preferredService) {
    for (id handle in handles) {
        if (![handle respondsToSelector:@selector(serviceName)]) continue;
        NSString *serviceName = [handle performSelector:@selector(serviceName)];
        if ([serviceName isKindOfClass:[NSString class]] &&
            [serviceName caseInsensitiveCompare:preferredService ?: @""] == NSOrderedSame) {
            return handle;
        }
    }
    return nil;
}

static id vendIMHandle(id registrar, NSString *address, NSString *preferredService,
                      BOOL allowFallback, BOOL createIfMissing) {
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return nil;
    }

    NSMutableArray *fallbackHandles = [NSMutableArray array];
    @try {
        if ([registrar respondsToSelector:@selector(IMHandleWithID:)]) {
            NSArray *handles = handlesFromCandidate([registrar performSelector:@selector(IMHandleWithID:)
                                                                       withObject:address]);
            id handle = handleMatchingService(handles, preferredService);
            if (handle) return handle;
            [fallbackHandles addObjectsFromArray:handles];
        }
        if ([registrar respondsToSelector:@selector(getIMHandlesForID:)]) {
            NSArray *handles = handlesFromCandidate([registrar performSelector:@selector(getIMHandlesForID:)
                                                                       withObject:address]);
            id handle = handleMatchingService(handles, preferredService);
            if (handle) return handle;
            [fallbackHandles addObjectsFromArray:handles];
        }
        // The registrar only knows existing handles. Let the active account
        // canonicalize and create first-contact iMessage handles before falling
        // back to a cached handle from another service.
        if (createIfMissing &&
            [preferredService caseInsensitiveCompare:@"iMessage"] == NSOrderedSame) {
            IMAccount *account = activeIMessageAccount();
            if ([account respondsToSelector:@selector(imHandleWithID:)]) {
                id handle = [account imHandleWithID:address];
                if (handle) return handle;
            }
        }
    } @catch (__unused NSException *ex) {
        return nil;
    }
    return allowFallback ? fallbackHandles.firstObject : nil;
}

static NSString *iMessageAvailabilityError(id handle, NSString *address) {
    // Account-vended handles do not prove reachability. Check their canonical
    // addresses before group creation or invitation can mutate a conversation.
    NSString *canonicalAddress = [handle respondsToSelector:@selector(ID)] ? [handle ID] : address;
    NSDictionary *check = handleCheckIMessageAvailability(0, @{
        @"address": canonicalAddress ?: address,
        @"aliasType": [address containsString:@"@"] ? @"email" : @"phone"
    });
    if (![check[@"success"] boolValue]) return [NSString stringWithFormat:
        @"Could not check iMessage availability for %@: %@", address, check[@"error"]];
    if ([check[@"available"] boolValue]) return nil;
    NSString *reason = [check[@"id_status"] integerValue] == 2
        ? @"is not reachable on iMessage; verify the address or use imsg send --service sms for a phone number"
        : @"could not confirm iMessage availability; check the Messages account and connection, then retry";
    return [NSString stringWithFormat:@"%@: %@", address, reason];
}

#pragma mark - Chat Resolution

static NSArray<NSString *>* chatIdentifierPrefixes(void) {
    return @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;", @"any;-;", @"any;+;"];
}

static NSString* stripKnownChatPrefix(NSString *value) {
    for (NSString *prefix in chatIdentifierPrefixes()) {
        if ([value hasPrefix:prefix]) {
            return [value substringFromIndex:prefix.length];
        }
    }
    return nil;
}

/// Try multiple methods to find a chat, including GUID lookup, chat identifier,
/// and participant matching with phone number normalization.
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-bridge] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-bridge] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;
    NSString *bareIdentifier = stripKnownChatPrefix(identifier) ?: identifier;

    // Method 1: Try existingChatWithGUID: with the identifier as-is (if it looks like a GUID)
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes (iMessage, SMS, any)
        for (NSString *prefix in chatIdentifierPrefixes()) {
            NSString *fullGUID = [prefix stringByAppendingString:bareIdentifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
        if (![bareIdentifier isEqualToString:identifier]) {
            chat = [registry performSelector:identSel withObject:bareIdentifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", bareIdentifier);
                return chat;
            }
        }
    }

    // Method 3: Iterate all chats and match by participant
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) {
            NSLog(@"[imsg-bridge] allExistingChats returned nil");
            return nil;
        }
        NSLog(@"[imsg-bridge] Searching %lu chats for identifier: %@",
              (unsigned long)allChats.count, identifier);

        // Normalize the search identifier for phone number matching
        NSString *normalizedIdentifier = nil;
        if (bareIdentifier.length > 0 &&
            ([bareIdentifier hasPrefix:@"+"] || [bareIdentifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet]
             characterIsMember:[bareIdentifier characterAtIndex:0]])) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < bareIdentifier.length; i++) {
                unichar c = [bareIdentifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier] ||
                    [chatGUID isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier] ||
                    [chatId isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                if (!participants) continue;
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        if ([handleID isEqualToString:identifier] ||
                            [handleID isEqualToString:bareIdentifier]) {
                            NSLog(@"[imsg-bridge] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                ([handleDigits hasSuffix:normalizedIdentifier] ||
                                 [normalizedIdentifier hasSuffix:handleDigits])) {
                                NSLog(@"[imsg-bridge] Found chat by normalized phone match: %@ ~ %@",
                                      handleID, identifier);
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-bridge] Chat not found for identifier: %@", identifier);
    return nil;
}

