#import <Foundation/Foundation.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

int main(void) {
    @autoreleasepool {
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"imsg-debug-log-%d", getpid()]];
        [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES
                                                attributes:nil error:nil];
        kDebugLogFile = [home stringByAppendingPathComponent:@".imsg-bridge.log"];
        kDebugLogRotated = [home stringByAppendingPathComponent:@".imsg-bridge.log.1"];

        // An oversized log moves aside before the next line is written.
        FILE *fp = fopen(kDebugLogFile.UTF8String, "w");
        fclose(fp);
        truncate(kDebugLogFile.UTF8String, (off_t)kDebugLogRotateBytes);
        debugLog(@"after rotation");

        struct stat rotated, current;
        BOOL ok = stat(kDebugLogRotated.UTF8String, &rotated) == 0 &&
            rotated.st_size == (off_t)kDebugLogRotateBytes &&
            stat(kDebugLogFile.UTF8String, &current) == 0 &&
            current.st_size < 64 &&
            [[NSString stringWithContentsOfFile:kDebugLogFile encoding:NSUTF8StringEncoding error:nil]
                hasSuffix:@" after rotation\n"];
        [NSFileManager.defaultManager removeItemAtPath:home error:nil];
        if (!ok) {
            fprintf(stderr, "FAIL: debug log must rotate once it reaches the size cap\n");
            return 1;
        }
        printf("DebugLogRotationTests passed\n");
        return 0;
    }
}
