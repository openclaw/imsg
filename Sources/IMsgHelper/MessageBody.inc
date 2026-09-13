#pragma mark - Resolve Chat (v2)

/// Resolve an IMChat from a chatGuid string (BlueBubbles-style addressing,
/// e.g. `iMessage;-;+15551234567` or `iMessage;+;chat0000`). Falls back to
/// `chatForIMHandle:` to materialize chats that don't yet exist in the
/// registry's allExistingChats snapshot. Returns nil if no chat could be
/// resolved or created.
static IMChat *resolveChatByGuid(NSString *chatGuid) {
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return nil;
    }
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return nil;
    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) return nil;

    if ([registry respondsToSelector:@selector(existingChatWithGUID:)]) {
        id chat = [registry performSelector:@selector(existingChatWithGUID:)
                                 withObject:chatGuid];
        if (chat) return chat;
    }

    // Fallback: parse a direct `<service>;-;<address>` guid and materialize
    // a chat using only a registered handle for the explicitly requested service.
    // First-contact creation belongs to the IDS-checked create/invite handlers.
    NSArray *parts = [chatGuid componentsSeparatedByString:@";"];
    if (parts.count == 3 && [parts[1] isEqualToString:@"-"]) {
        NSString *preferredService = parts.firstObject;
        NSString *address = parts.lastObject;
        Class hrClass = NSClassFromString(@"IMHandleRegistrar");
        if (hrClass) {
            id hr = [hrClass performSelector:@selector(sharedInstance)];
            id handle = vendIMHandle(hr, address, preferredService, NO, NO);
            if (handle && [registry respondsToSelector:@selector(chatForIMHandle:)]) {
                id chat = [registry performSelector:@selector(chatForIMHandle:)
                                         withObject:handle];
                if (chat) return chat;
            }
        }
    }
    return nil;
}

/// Resolve a chat by EITHER chatGuid (preferred) OR a free-form handle
/// (legacy path that walks `findChat`). Used to keep existing callers working.
static id resolveChatFlexible(NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if ([chatGuid isKindOfClass:[NSString class]] && chatGuid.length) {
        IMChat *chat = resolveChatByGuid(chatGuid);
        if (chat) return chat;
    }
    NSString *handle = params[@"handle"];
    if ([handle isKindOfClass:[NSString class]] && handle.length) {
        return findChat(handle);
    }
    return nil;
}

#pragma mark - AttributedBody Helpers

/// Decode a base64 NSKeyedArchiver blob into an NSAttributedString. Returns
/// nil on any decoding failure.
static NSAttributedString *attributedBodyFromBase64(NSString *b64) {
    if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) return nil;
    NSError *err = nil;
    NSSet *allowed = [NSSet setWithObjects:
        [NSAttributedString class], [NSDictionary class], [NSString class],
        [NSArray class], [NSNumber class], [NSURL class], [NSData class], nil];
    NSAttributedString *attr = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed
                                                                   fromData:data
                                                                      error:&err];
    if (err) {
        // Fall back to non-secure unarchiving for older blobs.
        @try {
            attr = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        } @catch (__unused NSException *ex) {
            attr = nil;
        }
    }
    return attr;
}

/// Build a plain NSAttributedString carrying `text` as message-part `partIndex`.
/// Applies the private `__kIMMessagePartAttributeName` attribute IMCore expects.
static NSAttributedString *buildPlainAttributed(NSString *text, NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSDictionary *attrs = @{
        @"__kIMMessagePartAttributeName": @(partIndex),
        @"__kIMBaseWritingDirectionAttributeName": @"-1"
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

static NSAttributedString *buildPollBreadcrumbAttributed(void) {
    NSString *placeholder = [NSString stringWithFormat:@"%C", (unichar)0xFFFD];
    NSDictionary *attrs = @{
        @"__kIMMessagePartAttributeName": @0,
        @"__kIMBreadcrumbTextMarkerAttributeName": @"Sent a poll",
        @"__kIMBreadcrumbTextOptionFlags": @0
    };
    return [[NSAttributedString alloc] initWithString:placeholder attributes:attrs];
}

/// Apply a JSON-shape array of text-formatting ranges to `text`. Each entry is
/// `{ "start": int, "length": int, "styles": ["bold"|"italic"|"underline"|"strikethrough", ...] }`.
/// macOS 15+ only — earlier OSes silently degrade to plain text (the private
/// IMText* attribute names don't exist before Sequoia). Attribute names and
/// range shape are based on BlueBubbles helper PR #50; implementation is local.
static NSMutableAttributedString *buildFormattedAttributed(NSString *text,
                                                            NSArray *formatting,
                                                            NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text];
    NSUInteger len = text.length;

    // Always carry the same base IM attributes as plain sends across the
    // whole string, then layer style ranges on top when supported.
    if (len > 0) {
        [attr addAttribute:@"__kIMMessagePartAttributeName" value:@(partIndex)
                     range:NSMakeRange(0, len)];
        [attr addAttribute:@"__kIMBaseWritingDirectionAttributeName" value:@"-1"
                     range:NSMakeRange(0, len)];
    }

    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 15) {
        return attr;  // Pre-Sequoia: no IMText* attributes; ship plain.
    }
    if (len == 0 || ![formatting isKindOfClass:[NSArray class]] || formatting.count == 0) {
        return attr;
    }

    for (id raw in formatting) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = (NSDictionary *)raw;
        NSNumber *startNum = r[@"start"];
        NSNumber *lengthNum = r[@"length"];
        NSArray *styles = r[@"styles"];
        if (![startNum isKindOfClass:[NSNumber class]]) continue;
        if (![lengthNum isKindOfClass:[NSNumber class]]) continue;
        if (![styles isKindOfClass:[NSArray class]]) continue;
        NSInteger start = startNum.integerValue;
        NSInteger length = lengthNum.integerValue;
        if (start < 0 || length <= 0) continue;
        if ((NSUInteger)(start + length) > len) continue;

        NSRange range = NSMakeRange((NSUInteger)start, (NSUInteger)length);
        if ([styles containsObject:@"bold"]) {
            [attr addAttribute:@"__kIMTextBoldAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"italic"]) {
            [attr addAttribute:@"__kIMTextItalicAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"underline"]) {
            [attr addAttribute:@"__kIMTextUnderlineAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"strikethrough"]) {
            [attr addAttribute:@"__kIMTextStrikethroughAttributeName" value:@1 range:range];
        }
    }
    return attr;
}

