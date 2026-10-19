#import <Foundation/Foundation.h>
static Class mutationTestClass(NSString *name) {
    NSDictionary *classes = @{
        @"IMChatRegistry": @"MutationRegistry", @"IMChatHistoryController": @"MutationHistory",
        @"IMMessagePartChatItem": @"MutationPart"
    };
    if (classes[name]) return NSClassFromString(classes[name]);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString mutationTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger mutations;
static NSUInteger failures;
static id currentMessage;

@interface MutationItem : NSObject
@property BOOL isFromMe;
@property NSArray *parts;
@end
@implementation MutationItem
- (NSArray *)_newChatItems { return self.parts; }
@end

@interface MutationPart : NSObject
@property NSInteger index;
@property id messageItem;
@end
@implementation MutationPart
- (id)message { return self.messageItem; }
@end

@interface MutationParent : NSObject
@property id backing;
@end
@implementation MutationParent
- (id)_imMessageItem { return self.backing; }
@end

@interface MutationHistory : NSObject
@end
@implementation MutationHistory
+ (id)sharedInstance { return [self new]; }
- (void)loadMessageWithGUID:(NSString *)guid completionBlock:(void (^)(id))completion {
    completion(currentMessage);
}
@end

@interface MutationChat : NSObject
@end
@implementation MutationChat
- (void)editMessageItem:(id)item atPartIndex:(NSInteger)part withNewPartText:(id)text
    backwardCompatabilityText:(id)compatibility { mutations++; }
- (void)editMessageItem:(id)item atPartIndex:(NSInteger)part withNewPartText:(id)text
    newPartTranslation:(id)translation backwardCompatabilityText:(id)compatibility { mutations++; }
- (void)editMessage:(id)item atPartIndex:(NSInteger)part withNewPartText:(id)text
    backwardCompatabilityText:(id)compatibility { mutations++; }
- (void)retractMessagePart:(id)part { mutations++; }
@end

@interface MutationRegistry : NSObject
@end
@implementation MutationRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid { return [MutationChat new]; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

int main(void) {
    @autoreleasepool {
        MutationItem *item = [MutationItem new];
        MutationPart *part = [MutationPart new];
        part.messageItem = item;
        item.parts = @[part];
        MutationParent *parent = [MutationParent new];
        parent.backing = item;
        currentMessage = parent;
        gHasRetractMessagePart = YES;
        NSDictionary *params = @{
            @"chatGuid": @"iMessage;-;self@example.invalid", @"messageGuid": @"fixture-guid",
            @"editedMessage": @"edited", @"partIndex": @0
        };
        for (NSNumber *outgoing in @[@NO, @YES]) {
            item.isFromMe = outgoing.boolValue;
            for (NSInteger mode = 0; mode < 3; mode++) {
                gHasEditMessageItemTranslation = mode == 0;
                gHasEditMessageItem = mode == 1;
                gHasEditMessage = mode == 2;
                mutations = 0;
                NSDictionary *result = handleEditMessage(1, params);
                check([result[@"success"] boolValue] == outgoing.boolValue,
                      @"Only the sent copy can be edited");
                check(mutations == (outgoing.boolValue ? 1 : 0),
                      @"Received echoes never reach an edit selector");
                if (!outgoing.boolValue) {
                    check([result.description containsString:@"sent copy"],
                          @"The error explains how to select the sent copy");
                }
            }
            mutations = 0;
            NSDictionary *result = handleUnsendMessage(2, params);
            check([result[@"success"] boolValue] == outgoing.boolValue,
                  @"Only the sent copy can be unsent");
            check(mutations == (outgoing.boolValue ? 1 : 0),
                  @"Received echoes never reach the retract selector");
        }
        MutationPart *unknown = [MutationPart new];
        unknown.messageItem = [NSObject new];
        currentMessage = unknown;
        mutations = 0;
        NSDictionary *unknownEdit = handleEditMessage(3, params);
        NSDictionary *unknownUnsend = handleUnsendMessage(4, params);
        check(![unknownEdit[@"success"] boolValue] && ![unknownUnsend[@"success"] boolValue],
              @"Unknown sender ownership fails closed");
        check(mutations == 0, @"Unknown ownership never dispatches a mutation");
        fprintf(stderr, "Mutation ownership tests: %lu failure(s)\n", (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
