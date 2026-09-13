static NSString *urlPreviewBalloonBundleIdentifier(void) {
    return @"com.apple.messages.URLBalloonProvider";
}

static BOOL urlPreviewMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return NO;
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:);
    return [messageClass instancesRespondToSelector:sel];
}

static IMsgRichLinkImageAttachmentArchiveProxy *makeURLPreviewImageSubstitute(
    NSString *mimeType) {
    IMsgRichLinkImageAttachmentArchiveProxy *substitute =
        [IMsgRichLinkImageAttachmentArchiveProxy new];
    substitute.richLinkImageAttachmentSubstituteIndex = 0;
    substitute.MIMEType = mimeType.length ? mimeType : @"image/png";
    substitute.imageType = 0;
    substitute.hasSingleDominantColor = NO;
    substitute.dominantColor = YES;
    substitute.dominantColorRed = 0.1686274509803922;
    substitute.dominantColorGreen = 0.1686274509803922;
    substitute.dominantColorBlue = 0.1764705882352941;
    substitute.dominantColorAlpha = 1.0;
    return substitute;
}

static BOOL replaceURLPreviewImagesWithAttachmentSubstitute(LPLinkMetadata *metadata,
                                                            NSString *mimeType) {
    if (!metadata) return NO;
    IMsgRichLinkImageAttachmentArchiveProxy *substitute =
        makeURLPreviewImageSubstitute(mimeType);
    @try {
        [metadata setValue:nil forKey:@"image"];
        [metadata setValue:nil forKey:@"icon"];
        [metadata setValue:@[substitute] forKey:@"contentImages"];
        NSArray *installed = [metadata valueForKey:@"contentImages"];
        if ([installed containsObject:substitute]) return YES;
    } @catch (NSException *exception) {
        @try {
            [metadata setValue:nil forKey:@"_image"];
            [metadata setValue:nil forKey:@"_icon"];
            [metadata setValue:@[substitute] forKey:@"_contentImages"];
            NSArray *installed = [metadata valueForKey:@"_contentImages"];
            if ([installed containsObject:substitute]) return YES;
        } @catch (NSException *ignored) {
            debugLog(@"rich-link: could not install image substitute: %@",
                     ignored.reason ?: exception.reason ?: @"unknown");
        }
    }
    return NO;
}

static NSURL *validatedRichLinkURL(id rawValue, NSString **outErr) {
    if (![rawValue isKindOfClass:[NSString class]]) {
        if (outErr) *outErr = @"Rich-link URL must be a string";
        return nil;
    }
    NSString *value = [(NSString *)rawValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!value.length || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192) {
        if (outErr) *outErr = @"Rich-link URL is empty or too long";
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:value];
    NSString *scheme = components.scheme.lowercaseString;
    if (!components ||
        !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
        !components.host.length || components.user.length || components.password.length) {
        if (outErr) *outErr = @"Rich-link URL must be HTTP(S), include a host, and omit credentials";
        return nil;
    }
    components.scheme = scheme;
    NSURL *url = components.URL;
    if (!url || [url.absoluteString lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192) {
        if (outErr) *outErr = @"Rich-link URL could not be normalized";
        return nil;
    }
    return url;
}

static NSData *buildURLPreviewPayloadData(NSDictionary *descriptor,
                                          BOOL includeImageSubstitute,
                                          NSString *previewMimeType,
                                          BOOL *outImageSubstituteInstalled,
                                          NSString **outErr) {
    NSSet *allowedKeys = [NSSet setWithArray:@[
        @"version", @"originalURL", @"resolvedURL", @"title", @"image"
    ]];
    for (id key in descriptor) {
        if (![key isKindOfClass:[NSString class]] || ![allowedKeys containsObject:key]) {
            if (outErr) *outErr = @"Invalid rich-link descriptor";
            return nil;
        }
    }
    NSNumber *version = descriptor[@"version"];
    if (![descriptor isKindOfClass:[NSDictionary class]] ||
        !richLinkIntegerNumber(version) || version.integerValue != 1) {
        if (outErr) *outErr = @"Invalid rich-link descriptor version";
        return nil;
    }
    NSString *urlError = nil;
    NSURL *originalURL = validatedRichLinkURL(descriptor[@"originalURL"], &urlError);
    NSURL *resolvedURL = validatedRichLinkURL(descriptor[@"resolvedURL"], &urlError);
    if (!originalURL || !resolvedURL) {
        if (outErr) *outErr = urlError ?: @"Invalid rich-link URL";
        return nil;
    }
    NSString *title = [descriptor[@"title"] isKindOfClass:[NSString class]]
        ? descriptor[@"title"] : @"";
    if (!title.length || [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 ||
        [title rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location !=
            NSNotFound) {
        if (outErr) *outErr = @"Invalid rich-link title";
        return nil;
    }

    LPLinkMetadata *metadata = [LPLinkMetadata new];
    metadata.URL = resolvedURL;
    metadata.originalURL = originalURL;
    metadata.title = title;
    BOOL imageSubstituteInstalled = NO;
    if (includeImageSubstitute) {
        imageSubstituteInstalled =
            replaceURLPreviewImagesWithAttachmentSubstitute(metadata, previewMimeType);
    }
    if (outImageSubstituteInstalled) {
        *outImageSubstituteInstalled = imageSubstituteInstalled;
    }

    IMsgRichLinkArchiveProxy *richLink = [IMsgRichLinkArchiveProxy new];
    richLink.richLinkMetadata = metadata;
    richLink.richLinkIsPlaceholder = NO;

    NSData *payload = nil;
    @try {
        NSKeyedArchiver *archiver =
            [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        [archiver setClassName:@"RichLink"
                     forClass:[IMsgRichLinkArchiveProxy class]];
        [archiver setClassName:@"RichLinkImageAttachmentSubstitute"
                     forClass:[IMsgRichLinkImageAttachmentArchiveProxy class]];
        [archiver encodeObject:richLink forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        if (archiver.error) {
            if (outErr) *outErr = archiver.error.localizedDescription;
            return nil;
        }
        payload = [archiver.encodedData copy];
    } @catch (NSException *exception) {
        if (outErr) *outErr = exception.reason ?: @"Could not archive URL metadata";
        return nil;
    }
    if (!payload.length || payload.length > 1024 * 1024) {
        if (outErr) *outErr = @"Rich-link payload is empty or too large";
        return nil;
    }
    return payload;
}

