#import <Foundation/Foundation.h>
static Class deleteTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMChatRegistry": @"DeleteRegistry", @"IMChatHistoryController": @"DeleteHistory",
        @"IMMessagePartChatItem": @"DeletePart", @"IMAssociatedMessageItem": @"DeleteTapbackItem",
        @"IMMessageRetractionChatItem": @"DeleteRetraction"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString deleteTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;

@interface DeletePart : NSObject
@property NSString *guid;
@property BOOL isAttachment;
@property NSArray *chatItems;
@property id backingItem;
@end
@implementation DeletePart
- (id)_item { return self.backingItem; }
@end

@interface DeleteRetraction : DeletePart
@end
@implementation DeleteRetraction
@end

@interface DeleteTapbackItem : NSObject
@end
@implementation DeleteTapbackItem
@end

// What history loading returns: a standalone message whose chat items are new
// objects, never the chat's own transcript items.
@interface DeleteMessage : NSObject
@property NSString *guid;
@property id item;
@property BOOL hasAttachment;
@end
@implementation DeleteMessage
- (id)_imMessageItem { return self.item ?: self; }
- (NSArray *)_newChatItems {
    DeletePart *copy = [DeletePart new];
    copy.guid = self.guid;
    copy.isAttachment = self.hasAttachment;
    return @[copy];
}
@end

// What IMChat did on macOS 15 and 26: deleteChatItems: only removes items in the
// loaded transcript. A rebuilt item for a text message still deletes it, one for
// a photo with a caption deletes nothing, unsent placeholders never delete, and
// anything else is silently ignored.
@interface DeleteChat : NSObject
@property NSMutableArray *chatItems;
@property NSMutableDictionary<NSString *, NSArray *> *older;
@property NSMutableSet<NSString *> *tapbacks;
@property NSMutableSet<NSString *> *photos;
@property NSMutableArray<NSString *> *deleted;
@end
@implementation DeleteChat
- (void)deleteChatItems:(NSArray *)items {
    for (DeletePart *item in items) {
        for (DeletePart *live in [self.chatItems copy]) {
            if (![live.guid isEqualToString:item.guid]) continue;
            if ([live isKindOfClass:[DeleteRetraction class]]) continue;
            BOOL same = live == item || (!live.isAttachment && !item.isAttachment);
            if (!same) continue;
            [self.chatItems removeObjectIdenticalTo:live];
            [self.deleted addObject:live.guid];
        }
    }
}
- (void)loadMessagesBeforeAndAfterGUID:(NSString *)guid
       numberOfMessagesToLoadBeforeGUID:(NSUInteger)before
        numberOfMessagesToLoadAfterGUID:(NSUInteger)after
                        loadImmediately:(BOOL)immediately
                       threadIdentifier:(id)thread {
    [self.chatItems addObjectsFromArray:self.older[guid] ?: @[]];
}
@end

// An IMChat without the transcript loading selector.
@interface DeleteChatWithoutLoading : DeleteChat
@end
@implementation DeleteChatWithoutLoading
- (BOOL)respondsToSelector:(SEL)selector {
    if ([NSStringFromSelector(selector) hasPrefix:@"loadMessagesBeforeAndAfterGUID:"]) return NO;
    return [super respondsToSelector:selector];
}
@end

static DeleteChat *chat;
static NSMutableSet<NSString *> *knownGuids;

@interface DeleteHistory : NSObject
@end
@implementation DeleteHistory
+ (id)sharedInstance { return [self new]; }
- (void)loadMessageWithGUID:(NSString *)guid completionBlock:(void (^)(id))completion {
    if (![knownGuids containsObject:guid]) { completion(nil); return; }
    DeleteMessage *message = [DeleteMessage new];
    message.guid = guid;
    message.hasAttachment = [chat.photos containsObject:guid];
    if ([chat.tapbacks containsObject:guid]) message.item = [DeleteTapbackItem new];
    completion(message);
}
@end

@interface DeleteRegistry : NSObject
@end
@implementation DeleteRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid { return chat; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

static DeleteChat *makeChat(Class chatClass) {
    DeleteChat *made = [chatClass new];
    made.chatItems = [NSMutableArray array];
    made.older = [NSMutableDictionary dictionary];
    made.tapbacks = [NSMutableSet set];
    made.photos = [NSMutableSet set];
    made.deleted = [NSMutableArray array];
    return made;
}

static NSArray *parts(NSString *guid, NSUInteger count, Class partClass) {
    [knownGuids addObject:guid];
    NSMutableArray *made = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        DeletePart *part = [partClass new];
        part.guid = guid;
        [made addObject:part];
    }
    return made;
}

static NSDictionary *deleteMessage(NSString *guid) {
    return handleDeleteMessage(1, @{@"chatGuid": @"iMessage;-;+15551234567", @"messageGuid": guid});
}

static BOOL notStarted(NSDictionary *result) {
    return ![result[@"success"] boolValue]
        && [result[@"delivery_disposition"] isEqualToString:@"not_started"];
}

int main(void) {
    @autoreleasepool {
        knownGuids = [NSMutableSet set];
        chat = makeChat([DeleteChat class]);

        [chat.chatItems addObjectsFromArray:parts(@"loaded", 1, [DeletePart class])];
        NSDictionary *loaded = deleteMessage(@"loaded");
        check([loaded[@"success"] boolValue], @"A loaded message is deleted");
        check([chat.deleted containsObject:@"loaded"], @"The loaded message leaves the transcript");

        chat.older[@"older"] = parts(@"older", 1, [DeletePart class]);
        NSDictionary *older = deleteMessage(@"older");
        check([older[@"success"] boolValue], @"A message older than the transcript is deleted");
        check([chat.deleted containsObject:@"older"],
              @"Success means Messages was given the older message's own transcript item");

        NSArray *photoParts = parts(@"photo", 2, [DeletePart class]);
        ((DeletePart *)photoParts[0]).isAttachment = YES;
        [chat.photos addObject:@"photo"];
        [chat.chatItems addObjectsFromArray:photoParts];
        [chat.deleted removeAllObjects];
        NSDictionary *photo = deleteMessage(@"photo");
        check([photo[@"success"] boolValue], @"A photo with a caption is deleted");
        check(chat.deleted.count == 2, @"Both the photo and its caption are deleted");

        DeletePart *parent = parts(@"thread-parent", 1, [DeletePart class]).firstObject;
        parent.chatItems = parts(@"nested-reply", 1, [DeletePart class]);
        [chat.chatItems addObject:parent];
        [chat.deleted removeAllObjects];
        NSDictionary *nested = deleteMessage(@"nested-reply");
        check(notStarted(nested), @"A nested reply without its own transcript entry fails closed");
        check(chat.deleted.count == 0, @"Deleting a nested reply never deletes its ancestor");
        check([chat.chatItems containsObject:parent], @"The thread parent survives");

        [chat.chatItems addObjectsFromArray:parent.chatItems];
        NSDictionary *loadedReply = deleteMessage(@"nested-reply");
        check([loadedReply[@"success"] boolValue], @"A reply with its own transcript entry is deleted");
        check([chat.deleted isEqual:@[@"nested-reply"]], @"Only the requested reply is deleted");
        check([chat.chatItems containsObject:parent], @"The thread parent survives reply deletion");

        DeletePart *nativePart = parts(@"native-part", 1, [DeletePart class]).firstObject;
        DeleteMessage *nativeBacking = [DeleteMessage new];
        nativeBacking.guid = @"native-part";
        nativePart.backingItem = nativeBacking;
        nativePart.guid = @"p:0/native-part";
        [chat.chatItems addObject:nativePart];
        NSDictionary *native = deleteMessage(@"native-part");
        check([native[@"success"] boolValue], @"Native part GUIDs resolve through their own backing message");
        check(![chat.chatItems containsObject:nativePart], @"The native transcript part is deleted");

        parts(@"tapback", 0, [DeletePart class]);
        [chat.tapbacks addObject:@"tapback"];
        NSDictionary *tapback = deleteMessage(@"tapback");
        check(notStarted(tapback), @"A tapback is refused before anything is dispatched");

        [chat.chatItems addObjectsFromArray:parts(@"unsent", 1, [DeleteRetraction class])];
        NSDictionary *unsent = deleteMessage(@"unsent");
        check(notStarted(unsent), @"An unsent message is refused before anything is dispatched");
        check(![chat.deleted containsObject:@"unsent"], @"The unsent placeholder is left alone");

        chat = makeChat([DeleteChatWithoutLoading class]);
        chat.older[@"unloadable"] = parts(@"unloadable", 1, [DeletePart class]);
        NSDictionary *unloadable = deleteMessage(@"unloadable");
        check(notStarted(unloadable), @"Without the loading selector an older message fails closed");
        check(chat.deleted.count == 0, @"Nothing is deleted without the loading selector");

        NSDictionary *missing = deleteMessage(@"missing");
        check(notStarted(missing), @"An unknown message is refused before anything is dispatched");

        fprintf(stderr, "Delete message tests: %lu failure(s)\n", (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
