#pragma mark - Inbound Events (v2)

/// Append a single JSON object as a line to `.imsg-events.jsonl`. Rotates the
/// file once it crosses kEventsRotateBytes by renaming to `.1` (overwriting).
/// Safe to call from any thread (guarded by an unfair lock).
static void appendEvent(NSDictionary *evt) {
    if (![evt isKindOfClass:[NSDictionary class]]) return;
    initFilePaths();

    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:evt];
    if (out[@"ts"] == nil) {
        out[@"ts"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    }

    NSError *err = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:out options:0 error:&err];
    if (!body) return;

    os_unfair_lock_lock(&eventsLock);

    // Rotate if oversized.
    struct stat st;
    if (stat(kEventsFile.UTF8String, &st) == 0 && st.st_size >= (off_t)kEventsRotateBytes) {
        rename(kEventsFile.UTF8String, kEventsRotated.UTF8String);
    }

    FILE *fp = fopen(kEventsFile.UTF8String, "a");
    if (fp != NULL) {
        fwrite(body.bytes, 1, body.length, fp);
        fputc('\n', fp);
        fclose(fp);
    }

    os_unfair_lock_unlock(&eventsLock);
}

