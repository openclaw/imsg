#pragma mark - Messages in iCloud Handlers (v2)

// IMCloudKitHooks drives Messages in iCloud. Its daemon proxy refuses callers
// outside Messages.app, so a sync can only be started from the injected helper.
static NSString *const kICloudIsSyncingSelector = @"isSyncing";
static NSString *const kICloudLastSyncDateSelector = @"lastSyncDate";
static NSString *const kICloudStartSyncSelector = @"startUserInitiatedSync";

static NSDictionary *icloudSyncSelectorStatus(void) {
    Class hooksClass = NSClassFromString(@"IMCloudKitHooks");
    BOOL status = hooksClass
        && [(id)hooksClass respondsToSelector:@selector(sharedInstance)]
        && [hooksClass instancesRespondToSelector:NSSelectorFromString(kICloudIsSyncingSelector)]
        && [hooksClass instancesRespondToSelector:NSSelectorFromString(kICloudLastSyncDateSelector)];
    BOOL sync = status
        && [hooksClass instancesRespondToSelector:NSSelectorFromString(kICloudStartSyncSelector)];
    return @{@"status": @(status), @"sync": @(sync)};
}

/// The shared hooks instance, only when it responds to every named selector.
static id icloudSyncHooks(NSArray<NSString *> *selectorNames) {
    Class hooksClass = NSClassFromString(@"IMCloudKitHooks");
    if (!hooksClass || ![(id)hooksClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id hooks = ((id (*)(id, SEL))objc_msgSend)(hooksClass, @selector(sharedInstance));
    for (NSString *name in selectorNames) {
        if (![hooks respondsToSelector:NSSelectorFromString(name)]) return nil;
    }
    return hooks;
}

static NSDictionary *icloudSyncState(id hooks) {
    BOOL syncing = ((BOOL (*)(id, SEL))objc_msgSend)(
        hooks, NSSelectorFromString(kICloudIsSyncingSelector));
    id lastSyncDate = ((id (*)(id, SEL))objc_msgSend)(
        hooks, NSSelectorFromString(kICloudLastSyncDateSelector));
    NSString *lastSyncAt = [lastSyncDate isKindOfClass:[NSDate class]]
        ? [[NSISO8601DateFormatter new] stringFromDate:lastSyncDate]
        : nil;
    return @{@"syncing": @(syncing), @"last_sync_at": lastSyncAt ?: [NSNull null]};
}

static NSDictionary *handleGetICloudSyncStatus(NSInteger requestId, NSDictionary *params) {
    id hooks = icloudSyncHooks(@[kICloudIsSyncingSelector, kICloudLastSyncDateSelector]);
    if (!hooks) {
        return errorResponse(requestId,
            @"Messages in iCloud status is unavailable (IMCloudKitHooks isSyncing/lastSyncDate missing)");
    }
    @try {
        return successResponse(requestId, icloudSyncState(hooks));
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
}

/// `start-icloud-sync`: request a user-initiated sync, then report the state
/// immediately. The sync continues in the background; callers poll
/// `get-icloud-sync-status` for completion.
static NSDictionary *handleStartICloudSync(NSInteger requestId, NSDictionary *params) {
    id hooks = icloudSyncHooks(@[
        kICloudStartSyncSelector, kICloudIsSyncingSelector, kICloudLastSyncDateSelector
    ]);
    if (!hooks) {
        return errorResponseWithDisposition(requestId,
            @"Messages in iCloud sync is unavailable (IMCloudKitHooks startUserInitiatedSync missing)",
            @"not_started");
    }
    @try {
        ((void (*)(id, SEL))objc_msgSend)(hooks, NSSelectorFromString(kICloudStartSyncSelector));
        NSMutableDictionary *result = [icloudSyncState(hooks) mutableCopy];
        result[@"requested"] = @YES;
        return successResponse(requestId, result);
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
}
