#import <Foundation/Foundation.h>

static Class deletionClass(NSString *name) {
    if ([name isEqualToString:@"IMChatRegistry"]) return NSClassFromString(@"DeletionRegistry");
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString deletionClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSObject *targetChat;
static BOOL recoverableAvailable;
static BOOL deleteAvailable;
static BOOL removeAvailable;
static BOOL throwRecoverable;
static BOOL synchronous;
static NSArray *recoveredChats;
static NSDate *deleteDate;
static NSUInteger permanentCalls;
static NSUInteger failures;

@interface DeletionRegistry : NSObject
@end
@implementation DeletionRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid { return targetChat; }
- (BOOL)respondsToSelector:(SEL)selector {
    NSString *name = NSStringFromSelector(selector);
    if ([name isEqualToString:@"moveMessagesInChatsToRecentlyDeleted:deleteDate:synchronously:completionHandler:"])
        return recoverableAvailable;
    if ([name isEqualToString:@"deleteChat:"]) return deleteAvailable;
    if ([name isEqualToString:@"_chat_remove:"]) return removeAvailable;
    return [super respondsToSelector:selector];
}
- (void)moveMessagesInChatsToRecentlyDeleted:(NSArray *)chats deleteDate:(NSDate *)date
                             synchronously:(BOOL)sync completionHandler:(id)completion {
    if (throwRecoverable) @throw [NSException exceptionWithName:@"test" reason:@"sync failed" userInfo:nil];
    recoveredChats = chats;
    deleteDate = date;
    synchronous = sync;
}
- (void)deleteChat:(id)chat { permanentCalls++; }
- (void)_chat_remove:(id)chat { permanentCalls++; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}
static NSDictionary *deleteChat(void) {
    return handleDeleteChat(1, @{@"chatGuid": @"iMessage;+;synthetic-chat"});
}

int main(void) {
    @autoreleasepool {
        targetChat = [NSObject new];
        recoverableAvailable = deleteAvailable = removeAvailable = YES;
        NSDictionary *result = deleteChat();
        check([result[@"success"] boolValue], @"Recoverable deletion succeeds");
        check([recoveredChats isEqual:@[targetChat]], @"Only the requested chat moves to Recently Deleted");
        check(synchronous && [deleteDate isKindOfClass:NSDate.class], @"Deletion supplies a date and waits synchronously");
        check(permanentCalls == 0, @"Recoverable deletion is preferred to permanent removal");
        check([result[@"method"] isEqualToString:
            @"moveMessagesInChatsToRecentlyDeleted:deleteDate:synchronously:completionHandler:"],
            @"Result reports the selected recoverable method");

        throwRecoverable = YES;
        permanentCalls = 0;
        result = deleteChat();
        check(![result[@"success"] boolValue], @"A failed recoverable deletion reports failure");
        check(permanentCalls == 0, @"A failed recoverable deletion never falls through to permanent removal");
        throwRecoverable = NO;

        recoverableAvailable = NO;
        result = deleteChat();
        check([result[@"method"] isEqualToString:@"deleteChat:"], @"Older deleteChat selector remains supported");
        deleteAvailable = NO;
        result = deleteChat();
        check([result[@"method"] isEqualToString:@"_chat_remove:"], @"Older remove selector remains supported");
        removeAvailable = NO;
        check(![deleteChat()[@"success"] boolValue], @"Missing selectors fail closed");
        targetChat = nil;
        check(![deleteChat()[@"success"] boolValue], @"A missing chat fails closed");
        fprintf(stderr, "Chat deletion tests: %lu failure(s)\n", (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
