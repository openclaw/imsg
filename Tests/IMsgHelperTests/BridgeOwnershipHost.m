// Separate process hosting the real helper in an isolated container. No private
// frameworks are loaded; ping exercises the production queue and dispatcher.
#import <Foundation/Foundation.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *home = [NSString stringWithUTF8String:argv[1]];
        kCommandFile = [home stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [home stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [home stringByAppendingPathComponent:@".imsg-bridge-ready"];
        kOwnerLockFile = [home stringByAppendingPathComponent:@".imsg-bridge-owner.lock"];
        kRpcDir = [home stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kEventsFile = [home stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [home stringByAppendingPathComponent:@".imsg-events.jsonl.1"];
        kDebugLogFile = [home stringByAppendingPathComponent:@".imsg-bridge.log"];
        NSString *stop = [home stringByAppendingPathComponent:
            [NSString stringWithFormat:@"stop-%d", getpid()]];
        bridgeClaimOwnership();
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
        while (![NSFileManager.defaultManager fileExistsAtPath:stop] && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        // Normal process exit invokes the real destructor exactly once.
        return 0;
    }
}
