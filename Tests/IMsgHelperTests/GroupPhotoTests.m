#import <Foundation/Foundation.h>

static Class photoTestClass(NSString *name) {
    NSDictionary *classes = @{@"IMChatRegistry": @"PhotoRegistry",
                              @"IMFileTransferCenter": @"PhotoTransferCenter"};
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString photoTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger allocations, registrations, updates, clears, failures;
static NSData *transferredData;
static NSString *updatedGUID;

@interface PhotoTransfer : NSObject
@property NSString *guid;
@end
@implementation PhotoTransfer
@end
static PhotoTransfer *transfer;

@interface PhotoChat : NSObject
- (void)sendGroupPhotoUpdate:(NSString *)guid;
@end
@implementation PhotoChat
- (void)sendGroupPhotoUpdate:(NSString *)guid {
    updates++;
    if (!guid) clears++;
    updatedGUID = guid;
}
@end

@interface PhotoRegistry : NSObject
@end
@implementation PhotoRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    return [guid isEqualToString:@"iMessage;+;photo-fixture"] ? [PhotoChat new] : nil;
}
@end

@interface PhotoTransferCenter : NSObject
@end
@implementation PhotoTransferCenter
+ (id)sharedInstance { return [self new]; }
- (NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url {
    allocations++;
    transferredData = [NSData dataWithContentsOfURL:url];
    if (!transferredData) return nil;
    transfer = [PhotoTransfer new];
    transfer.guid = @"photo-transfer-guid";
    return transfer.guid;
}
- (id)transferForGUID:(NSString *)guid { return transfer; }
- (void)registerTransferWithDaemon:(NSString *)guid { registrations++; }
@end

static NSDictionary *invokePhoto(NSString *path) {
    allocations = registrations = updates = clears = 0;
    transferredData = nil;
    updatedGUID = nil;
    NSMutableDictionary *params = [@{@"chatGuid": @"iMessage;+;photo-fixture"} mutableCopy];
    if (path) params[@"filePath"] = path;
    return processV2Envelope(@{@"id": @"photo-proof", @"action": @"update-group-photo", @"params": params});
}

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2) {
            NSString *argument = [NSString stringWithUTF8String:argv[1]];
            NSDictionary *response = invokePhoto([argument isEqualToString:@"--clear"] ? nil : argument);
            NSMutableDictionary *proof = [response mutableCopy];
            proof[@"allocations"] = @(allocations);
            proof[@"registrations"] = @(registrations);
            proof[@"updates"] = @(updates);
            proof[@"clears"] = @(clears);
            proof[@"bytes"] = @(transferredData.length);
            NSData *json = [NSJSONSerialization dataWithJSONObject:proof options:NSJSONWritingSortedKeys error:NULL];
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *directory = [root stringByAppendingPathComponent:@"images"];
        check([fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL], @"Create fixture");
        NSString *file = [directory stringByAppendingPathComponent:@"photo.png"];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ZkAAAAASUVORK5CYII=" options:0];
        check([data writeToFile:file atomically:YES], @"Write synthetic photo");
        NSDictionary *regular = invokePhoto(file);
        check([regular[@"success"] boolValue], @"Regular photo succeeds");
        check(allocations == 1 && registrations == 1 && updates == 1 && clears == 0, @"Register before one photo update");
        check([transferredData isEqualToData:data] && [updatedGUID isEqualToString:@"photo-transfer-guid"], @"Transfer original bytes and GUID");
        NSString *link = [root stringByAppendingPathComponent:@"link.png"];
        NSString *parent = [root stringByAppendingPathComponent:@"linked-images"];
        check([fm createSymbolicLinkAtPath:link withDestinationPath:file error:NULL], @"Create final symlink");
        check([fm createSymbolicLinkAtPath:parent withDestinationPath:directory error:NULL], @"Create directory symlink");
        for (NSString *path in @[link, [parent stringByAppendingPathComponent:@"photo.png"]]) {
            NSDictionary *response = invokePhoto(path);
            check(![response[@"success"] boolValue] && [response[@"error"] containsString:@"symlink"], @"Reject symlink path");
            check(allocations == 0 && registrations == 0 && updates == 0, @"Reject before transfer or update");
        }
        NSDictionary *clear = invokePhoto(nil);
        check([clear[@"success"] boolValue] && [clear[@"data"][@"cleared"] boolValue], @"Clear succeeds");
        check(allocations == 0 && registrations == 0 && updates == 1 && clears == 1, @"Clear never allocates a transfer");
        [fm removeItemAtPath:root error:NULL];
        printf("Bridge group-photo tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
