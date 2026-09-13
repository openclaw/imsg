static unsigned long long flagsForMessagePayload(NSAttributedString *subject,
                                                 NSArray *fileTransferGuids,
                                                 BOOL isAudioMessage);

static NSString *pollsBalloonBundleIdentifier(void) {
    return @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls";
}

static BOOL pollPayloadMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:);
    return messageClass && [messageClass instancesRespondToSelector:sel];
}

static BOOL pollVoteMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
    return messageClass && [messageClass instancesRespondToSelector:sel];
}

static NSString *trimmedPollString(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *activeIMessageSenderHandle(void) {
    Class accClass = NSClassFromString(@"IMAccountController");
    id ctrl = accClass ? [accClass performSelector:@selector(sharedInstance)] : nil;
    id account = nil;
    if (ctrl && [ctrl respondsToSelector:@selector(activeIMessageAccount)]) {
        account = [ctrl performSelector:@selector(activeIMessageAccount)];
    }
    if (!account) return nil;

    id login = nil;
    if ([account respondsToSelector:@selector(loginIMHandle)]) {
        login = [account performSelector:@selector(loginIMHandle)];
    }
    if (login && [login respondsToSelector:@selector(ID)]) {
        NSString *loginID = [login performSelector:@selector(ID)];
        if (loginID.length) return loginID;
    }

    if ([account respondsToSelector:@selector(vettedAliases)]) {
        NSArray *aliases = [account performSelector:@selector(vettedAliases)];
        for (id alias in aliases) {
            NSString *candidate = trimmedPollString(alias);
            if (candidate.length) return candidate;
        }
    }
    return nil;
}

static NSString *pollParticipantHandle(NSString *handle) {
    NSString *trimmed = trimmedPollString(handle);
    if (!trimmed.length) return nil;
    if ([trimmed hasPrefix:@"e:"] || [trimmed hasPrefix:@"p:"]) {
        NSString *stripped = [trimmed substringFromIndex:2];
        return stripped.length ? stripped : trimmed;
    }
    return trimmed;
}

static NSArray<NSString *> *normalizedPollOptions(NSArray *rawOptions) {
    NSMutableArray<NSString *> *options = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id raw in rawOptions) {
        NSString *text = trimmedPollString(raw);
        if (!text.length) continue;
        if ([seen containsObject:text]) continue;
        [options addObject:text];
        [seen addObject:text];
    }
    return options;
}

static NSData *pollPreviewImageData(void) {
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:162
                                                pixelsHigh:162
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:0
                                              bitsPerPixel:0];
    if (!rep) return nil;

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!context) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    [[NSColor colorWithCalibratedRed:0.96 green:0.96 blue:0.98 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, 162, 162));

    [[NSColor colorWithCalibratedRed:0.16 green:0.40 blue:0.86 alpha:1.0] setFill];
    NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(25, 25, 112, 112)
                                                          xRadius:24
                                                          yRadius:24];
    [badge fill];

    [[NSColor whiteColor] setFill];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat y = 103 - (i * 28);
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(48, y, 10, 10)] fill];
        NSBezierPath *line = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(68, y + 1, 46, 8)
                                                             xRadius:4
                                                             yRadius:4];
        [line fill];
    }

    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                             properties:@{NSImageCompressionFactor: @0.82}];
}

static NSData *archivePollLiveLayoutInfo(NSError **outError) {
    NSDictionary *layoutInfo = @{
        @"layoutClass": @"MSMessageLiveLayout",
        @"userInfo": @{}
    };
    return [NSKeyedArchiver archivedDataWithRootObject:layoutInfo
                                 requiringSecureCoding:NO
                                                 error:outError];
}

static NSData *archivePollRequiredCapabilities(NSError **outError) {
    NSArray *capabilities = @[@"supports-polls"];
    return [NSKeyedArchiver archivedDataWithRootObject:capabilities
                                 requiringSecureCoding:NO
                                                 error:outError];
}

static NSData *archivePollPayloadEnvelope(NSURL *url,
                                          NSUUID *sessionIdentifier,
                                          NSError **outError) {
    NSData *previewImage = pollPreviewImageData();
    if (!previewImage.length) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"imsg.poll"
                                           code:1
                                       userInfo:@{
                NSLocalizedDescriptionKey: @"Could not render poll preview image"
            }];
        }
        return nil;
    }

    NSError *layoutError = nil;
    NSData *liveLayoutInfo = archivePollLiveLayoutInfo(&layoutError);
    if (!liveLayoutInfo.length) {
        if (outError) *outError = layoutError;
        return nil;
    }

    NSError *capabilitiesError = nil;
    NSData *requiredCapabilities = archivePollRequiredCapabilities(&capabilitiesError);
    if (!requiredCapabilities.length) {
        if (outError) *outError = capabilitiesError;
        return nil;
    }

    NSString *previewText = @"Sent a poll";
    NSDictionary *userInfo = @{
        @"caption": previewText,
        @"tertiary-subcaption": @"",
        @"image-subtitle": @"",
        @"subcaption": @"",
        @"image-title": @"",
        @"secondary-subcaption": @""
    };
    NSDictionary *envelope = @{
        @"userInfo": userInfo,
        @"ldtext": previewText,
        @"URL": url,
        @"layoutClass": @"MSMessageTemplateLayout",
        @"ai": previewImage,
        @"sessionIdentifier": sessionIdentifier,
        @"liveLayoutInfo": liveLayoutInfo,
        @"requiredCapabilities": requiredCapabilities,
        @"sendAsText": @YES,
        @"an": @"Polls"
    };
    return [NSKeyedArchiver archivedDataWithRootObject:envelope
                                 requiringSecureCoding:NO
                                                 error:outError];
}

/// Native vote rows carry only the Polls URL and session identity. Reusing the
/// creation envelope suppresses participant markers and native notifications.
static NSData *archivePollMutationEnvelope(NSURL *url,
                                           NSUUID *sessionIdentifier,
                                           NSError **outError) {
    NSDictionary *envelope = @{
        @"URL": url,
        @"an": @"Polls",
        @"sessionIdentifier": sessionIdentifier
    };
    return [NSKeyedArchiver archivedDataWithRootObject:envelope
                                 requiringSecureCoding:NO
                                                 error:outError];
}

static NSData *buildPollCreationPayloadData(NSString *question,
                                            NSArray<NSString *> *options,
                                            NSString *creatorHandle,
                                            NSString **outSessionIdentifier,
                                            NSArray<NSString *> **outOptionIdentifiers,
                                            NSString **outError) {
    NSMutableArray<NSDictionary *> *pollOptions = [NSMutableArray array];
    NSMutableArray<NSString *> *optionIdentifiers = [NSMutableArray array];
    for (NSString *optionText in options) {
        NSString *identifier = [[NSUUID UUID] UUIDString];
        [optionIdentifiers addObject:identifier];
        NSMutableDictionary *option = [NSMutableDictionary dictionaryWithDictionary:@{
            @"canBeEdited": @NO,
            @"attributedText": optionText,
            @"text": optionText,
            @"optionIdentifier": identifier
        }];
        if (creatorHandle.length) {
            option[@"creatorHandle"] = creatorHandle;
        }
        [pollOptions addObject:option];
    }

    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:@{
        @"title": question ?: @"",
        @"orderedPollOptions": pollOptions
    }];
    if (creatorHandle.length) {
        item[@"creatorHandle"] = creatorHandle;
    }
    NSDictionary *root = @{@"item": item, @"version": @1};

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!jsonData) {
        if (outError) *outError = jsonError.localizedDescription ?: @"Could not encode poll payload";
        return nil;
    }
    if (jsonData.length > 4096) {
        if (outError) *outError = @"Poll definition payload exceeds 4096 bytes";
        return nil;
    }

    NSString *encoded = [jsonData base64EncodedStringWithOptions:0];
    NSString *urlString = [NSString stringWithFormat:@"data:,%@?src=p&c=%lu",
                                                     encoded,
                                                     (unsigned long)options.count];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = @"Could not create poll URL";
        return nil;
    }

    NSUUID *sessionIdentifier = [NSUUID UUID];
    NSError *archiveError = nil;
    NSData *payload = archivePollPayloadEnvelope(url, sessionIdentifier, &archiveError);
    if (!payload) {
        if (outError) *outError = archiveError.localizedDescription ?: @"Could not archive poll payload";
        return nil;
    }

    if (outSessionIdentifier) {
        *outSessionIdentifier = sessionIdentifier.UUIDString;
    }
    if (outOptionIdentifiers) {
        *outOptionIdentifiers = optionIdentifiers;
    }
    return payload;
}

