static NSDictionary *handleCheckIMessageAvailability(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    NSString *aliasType = params[@"aliasType"] ?: @"phone";
    if (!address.length) return errorResponse(requestId, @"Missing address");
    Class q = NSClassFromString(@"IDSIDQueryController");
    if (!q) return errorResponse(requestId, @"IDSIDQueryController unavailable");
    id ctrl = nil;
    @try {
        if ([q respondsToSelector:@selector(sharedInstance)]) {
            ctrl = ((id (*)(id, SEL))objc_msgSend)(q, @selector(sharedInstance));
        } else if ([q respondsToSelector:@selector(sharedController)]) {
            ctrl = ((id (*)(id, SEL))objc_msgSend)(q, @selector(sharedController));
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"controller unavailable");
    }
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSString *destination = address;
    if ([aliasType isEqualToString:@"phone"]) {
        if (![destination hasPrefix:@"tel:"]) destination = [@"tel:" stringByAppendingString:destination];
    } else if ([aliasType isEqualToString:@"email"]) {
        if (![destination hasPrefix:@"mailto:"]) destination = [@"mailto:" stringByAppendingString:destination];
    }

    NSInteger status = 0;
    @try {
        SEL privateSel = @selector(_currentIDStatusForDestination:service:listenerID:);
        if ([ctrl respondsToSelector:privateSel]) {
            status = ((NSInteger (*)(id, SEL, id, id, id))objc_msgSend)(
                ctrl, privateSel, destination, @"com.apple.madrid", @"imsg-bridge");
        } else {
            SEL sel = @selector(currentIDStatusForDestination:service:);
            if ([ctrl respondsToSelector:sel]) {
                id result = [ctrl performSelector:sel withObject:destination withObject:nil];
                if ([result isKindOfClass:[NSNumber class]]) {
                    status = [(NSNumber *)result integerValue];
                }
            }
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"availability check failed");
    }

    return successResponse(requestId, @{
        @"address": address,
        @"alias_type": aliasType,
        @"destination": destination,
        @"id_status": @(status),
        @"available": @(status == 1)
    });
}

static NSDictionary *handleDownloadPurgedAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *attachmentGuid = params[@"attachmentGuid"];
    if (!attachmentGuid.length) return errorResponse(requestId, @"Missing attachmentGuid");
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    id ftc = ftcClass ? [ftcClass performSelector:@selector(sharedInstance)] : nil;
    if (!ftc) return errorResponse(requestId, @"FileTransferCenter unavailable");

    SEL sel = @selector(acceptTransfer:);
    if (![ftc respondsToSelector:sel]) {
        return errorResponse(requestId, @"acceptTransfer: not available");
    }
    @try {
        [ftc performSelector:sel withObject:attachmentGuid];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"attachmentGuid": attachmentGuid, @"queued": @YES});
}

