//
//  IMsgInjected.m
//  IMsgHelper - Injectable dylib for Messages.app
//
//  This dylib is injected into Messages.app via DYLD_INSERT_LIBRARIES
//  to gain access to IMCore's chat registry and messaging functions.
//  It provides file-based IPC for the CLI to send commands.
//
//  Requires SIP disabled for DYLD_INSERT_LIBRARIES to work on system apps.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <LinkPresentation/LinkPresentation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <errno.h>
#import <fcntl.h>
#import <pwd.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <signal.h>
#import <sys/stat.h>
#import <dlfcn.h>

// IMCore C function. The symbol lives in the dyld shared cache on macOS 26
// and isn't picked up by the static linker, so resolve dynamically. Given a
// parent message's first IMMessagePartChatItem, returns the thread
// identifier string ("0:0:<parent-len>:<parent-guid>") to set on the reply.
typedef NSString *(*IMCreateThreadIdentifierForMessagePartChatItemFn)(id);

@interface IMsgRichLinkArchiveProxy : NSObject <NSSecureCoding>
@property (nonatomic, strong) id richLinkMetadata;
@property (nonatomic, assign) BOOL richLinkIsPlaceholder;
@end

@implementation IMsgRichLinkArchiveProxy
+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.richLinkMetadata forKey:@"richLinkMetadata"];
    [coder encodeBool:self.richLinkIsPlaceholder forKey:@"richLinkIsPlaceholder"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _richLinkMetadata = [coder decodeObjectForKey:@"richLinkMetadata"];
        _richLinkIsPlaceholder = [coder decodeBoolForKey:@"richLinkIsPlaceholder"];
    }
    return self;
}
@end

@interface IMsgRichLinkImageAttachmentArchiveProxy : NSObject <NSSecureCoding>
@property (nonatomic, assign) NSInteger richLinkImageAttachmentSubstituteIndex;
@property (nonatomic, copy) NSString *MIMEType;
@property (nonatomic, assign) NSInteger imageType;
@property (nonatomic, assign) BOOL hasSingleDominantColor;
@property (nonatomic, assign) BOOL dominantColor;
@property (nonatomic, assign) CGFloat dominantColorRed;
@property (nonatomic, assign) CGFloat dominantColorGreen;
@property (nonatomic, assign) CGFloat dominantColorBlue;
@property (nonatomic, assign) CGFloat dominantColorAlpha;
@end

@implementation IMsgRichLinkImageAttachmentArchiveProxy
+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:self.richLinkImageAttachmentSubstituteIndex
                 forKey:@"richLinkImageAttachmentSubstituteIndex"];
    [coder encodeObject:self.MIMEType ?: @"image/png" forKey:@"MIMEType"];
    [coder encodeInteger:self.imageType forKey:@"imageType"];
    [coder encodeBool:self.hasSingleDominantColor forKey:@"hasSingleDominantColor"];
    [coder encodeBool:self.dominantColor forKey:@"dominantColor"];
    [coder encodeDouble:self.dominantColorRed forKey:@"dominantColor.red"];
    [coder encodeDouble:self.dominantColorGreen forKey:@"dominantColor.green"];
    [coder encodeDouble:self.dominantColorBlue forKey:@"dominantColor.blue"];
    [coder encodeDouble:self.dominantColorAlpha forKey:@"dominantColor.alpha"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _richLinkImageAttachmentSubstituteIndex =
            [coder decodeIntegerForKey:@"richLinkImageAttachmentSubstituteIndex"];
        _MIMEType = [coder decodeObjectForKey:@"MIMEType"];
        _imageType = [coder decodeIntegerForKey:@"imageType"];
        _hasSingleDominantColor = [coder decodeBoolForKey:@"hasSingleDominantColor"];
        _dominantColor = [coder decodeBoolForKey:@"dominantColor"];
        _dominantColorRed = [coder decodeDoubleForKey:@"dominantColor.red"];
        _dominantColorGreen = [coder decodeDoubleForKey:@"dominantColor.green"];
        _dominantColorBlue = [coder decodeDoubleForKey:@"dominantColor.blue"];
        _dominantColorAlpha = [coder decodeDoubleForKey:@"dominantColor.alpha"];
    }
    return self;
}
@end

static IMCreateThreadIdentifierForMessagePartChatItemFn
imCreateThreadIdentifierFn(void) {
    static IMCreateThreadIdentifierForMessagePartChatItemFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (IMCreateThreadIdentifierForMessagePartChatItemFn)
            dlsym(RTLD_DEFAULT,
                  "IMCreateThreadIdentifierForMessagePartChatItem");
    });
    return fn;
}

#pragma mark - Constants

// v1 (legacy) single-file IPC paths.
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;

// v2 queue-directory IPC paths.
static NSString *kRpcDir = nil;       // .imsg-rpc/
static NSString *kRpcInDir = nil;     // .imsg-rpc/in/
static NSString *kRpcOutDir = nil;    // .imsg-rpc/out/
static NSString *kEventsFile = nil;   // .imsg-events.jsonl
static NSString *kEventsRotated = nil;// .imsg-events.jsonl.1

// Diagnostic file logger. Unified logging redacts NSLog output from inside
// system app processes on macOS 26, which makes diagnosing handler behavior
// from outside the dylib painful. Append-only file in the sandbox container
// gives us a stable channel that's readable from outside.
static NSString *kDebugLogFile = nil; // .imsg-bridge.log

static NSTimer *fileWatchTimer = nil;
static NSTimer *rpcInboxTimer = nil;
static BOOL bridgeDidBootstrap = NO;
static os_unfair_lock eventsLock = OS_UNFAIR_LOCK_INIT;
static int lockFd = -1;

static const NSUInteger kEventsRotateBytes = 1 * 1024 * 1024;
static const NSTimeInterval kV2ClaimMaxAge = 10 * 60;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Messages.app runs in a container; NSHomeDirectory() resolves to
        // ~/Library/Containers/com.apple.MobileSMS/Data inside the sandbox.
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge-ready"];
        kRpcDir = [containerPath stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kEventsFile = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl.1"];
        kDebugLogFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge.log"];
    }
}

/// Append a line to `.imsg-bridge.log` inside the Messages container. NSLog
/// output is redacted by unified logging when emitted from system apps on
/// macOS 26, so this is the only reliable diagnostic channel for behavior
/// inside the injected dylib.
__attribute__((format(NSString, 1, 2)))
static void debugLog(NSString *fmt, ...) {
    if (!kDebugLogFile) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSISO8601DateFormatter *fmtr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmtr = [NSISO8601DateFormatter new]; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [fmtr stringFromDate:[NSDate date]], msg];
    FILE *fp = fopen(kDebugLogFile.UTF8String, "a");
    if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
}

#pragma mark - Path Hardening

// Returns YES if any component of `path` (after tilde expansion and CWD
// resolution for relative paths) is a symbolic link, including the final
// component. Mirrors `SecurePath.hasSymlinkComponent` in IMsgCore: realpath()
// alone isn't enough because macOS rewrites `/tmp` -> `/private/tmp`, breaking
// any "resolved == lexical" check. Walking each component with lstat() and
// rejecting on S_IFLNK is the robust answer.
//
// Used to refuse RPC queue dirs and attachment paths that traverse a symlink
// at any level, closing the same-UID-attacker exfiltration path where someone
// drops a symlink to ~/.ssh/id_rsa or a password-manager DB and has Messages
// send it as an attachment to an attacker-controlled handle.
static NSString *normalizeTrustedSystemAliasPrefix(NSString *path) {
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"/tmp": @"/private/tmp",
        @"/var": @"/private/var",
        @"/etc": @"/private/etc",
    };
    for (NSString *alias in aliases) {
        if ([path isEqualToString:alias]) {
            return aliases[alias];
        }
        NSString *prefix = [alias stringByAppendingString:@"/"];
        if ([path hasPrefix:prefix]) {
            return [aliases[alias] stringByAppendingString:
                [path substringFromIndex:alias.length]];
        }
    }
    return path;
}

static BOOL pathHasSymlinkComponent(NSString *path) {
    NSString *lexicalPath = [path stringByExpandingTildeInPath];
    if (!lexicalPath.isAbsolutePath) {
        lexicalPath = [[[NSFileManager defaultManager] currentDirectoryPath]
            stringByAppendingPathComponent:lexicalPath];
    }
    lexicalPath = normalizeTrustedSystemAliasPrefix(lexicalPath);

    NSArray *components = [lexicalPath pathComponents];
    if (components.count == 0) return NO;

    NSString *cursor = [components.firstObject isEqualToString:@"/"] ? @"/" : @"";
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        cursor = [cursor stringByAppendingPathComponent:component];

        struct stat st;
        if (lstat([cursor fileSystemRepresentation], &st) != 0) {
            continue;
        }
        if (S_ISLNK(st.st_mode)) {
            return YES;
        }
    }
    return NO;
}

static BOOL ensureSecureDirectory(NSString *path, NSError **error) {
    if (pathHasSymlinkComponent(path)) {
        if (error) {
            *error = [NSError errorWithDomain:@"imsg.bridge"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RPC queue path traverses a symlink"
            }];
        }
        return NO;
    }

    NSDictionary *secureMode = @{ NSFilePosixPermissions: @(0700) };
    BOOL ok = [[NSFileManager defaultManager]
        createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:secureMode
                        error:error];
    if (!ok) return NO;
    if (pathHasSymlinkComponent(path)) {
        if (error) {
            *error = [NSError errorWithDomain:@"imsg.bridge"
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RPC queue path traverses a symlink (post-mkdir)"
            }];
        }
        return NO;
    }
    chmod([path fileSystemRepresentation], 0700);
    return YES;
}

#pragma mark - Selector Probes

// Populated at startup by probeSelectors(). Surfaced via the `status` action so
// the CLI can report which IMCore selectors are present on the running macOS
// (edit/unsend names changed across 13/14/15).
static BOOL gHasEditMessageItem = NO;        // editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:
static BOOL gHasEditMessage = NO;            // editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:
static BOOL gHasRetractMessagePart = NO;     // retractMessagePart:
static BOOL gHasSendMessageReason = NO;      // sendMessage:reason:

static BOOL pollPayloadMessageInitializerAvailable(void);
static BOOL pollVoteMessageInitializerAvailable(void);
static NSDictionary *nicknameSharingSelectorStatus(void);
static BOOL urlPreviewMessageInitializerAvailable(void);

static void probeSelectors(void) {
    Class chatClass = NSClassFromString(@"IMChat");
    if (!chatClass) return;
    gHasEditMessageItem = [chatClass instancesRespondToSelector:
        @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasEditMessage = [chatClass instancesRespondToSelector:
        @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasRetractMessagePart = [chatClass instancesRespondToSelector:
        @selector(retractMessagePart:)];
    gHasSendMessageReason = [chatClass instancesRespondToSelector:
        @selector(sendMessage:reason:)];
    NSLog(@"[imsg-bridge] Selector probes: editItem=%d editLegacy=%d retract=%d sendReason=%d",
          gHasEditMessageItem, gHasEditMessage, gHasRetractMessagePart, gHasSendMessageReason);
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMHandle : NSObject
- (NSString *)ID;
- (NSString *)serviceName;
@end

@interface IMAccount : NSObject
- (NSArray *)vettedAliases;
- (id)loginIMHandle;
- (id)imHandleWithID:(NSString *)handleID;
- (NSString *)serviceName;
- (BOOL)isActive;
@end

@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
- (IMAccount *)activeIMessageAccount;
- (NSArray *)activeAccounts;
@end

@interface IMHandleRegistrar : NSObject
+ (instancetype)sharedInstance;
- (id)IMHandleWithID:(NSString *)handleID;
- (id)getIMHandlesForID:(NSString *)handleID;
@end

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
- (id)chatForIMHandle:(id)handle;
- (id)chatForIMHandles:(NSArray *)handles;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (NSString *)displayName;
- (id)lastMessage;
- (id)lastSentMessage;
- (id)account;
- (NSString *)lastAddressedHandleID;
- (NSString *)displayNameForChat;
- (void)sendMessage:(id)message;
- (void)_sendMessage:(id)message adjustingSender:(BOOL)adjust shouldQueue:(BOOL)queue;
- (void)leaveChat;
- (void)_setDisplayName:(NSString *)name;
- (BOOL)hasUnreadMessages;
- (NSArray *)chatItems;
- (void)inviteParticipantsToiMessageChat:(NSArray *)participants reason:(NSInteger)reason;
- (void)markLastMessageAsUnread;
- (void)markChatItemAsNotifyRecipient:(id)chatItem;
- (void)sendGroupPhotoUpdate:(NSString *)transferGUID;
@end

@interface IMMessage : NSObject
- (NSString *)guid;
- (id)sender;
- (NSDate *)time;
- (NSAttributedString *)text;
- (NSAttributedString *)subject;
- (NSArray *)fileTransferGUIDs;
- (id)_imMessageItem;
- (NSString *)threadIdentifier;
- (void)_updateText:(NSAttributedString *)attributedText;
- (void)setThreadIdentifier:(NSString *)threadIdentifier;
- (void)setThreadOriginator:(id)originator;
+ (id)messageFromIMMessageItem:(id)item sender:(id)sender subject:(id)subject;
@end

@interface IMMessageItem : NSObject
- (NSString *)guid;
- (NSArray *)_newChatItems;
- (id)message;
- (NSData *)bodyData;
- (id)body;
- (void)setBodyData:(NSData *)data;
- (void)_regenerateBodyData;
- (id)initWithSender:(id)sender
                time:(NSDate *)time
                body:(NSAttributedString *)body
          attributes:(NSDictionary *)attributes
   fileTransferGUIDs:(NSArray *)fileTransferGUIDs
               flags:(unsigned long long)flags
               error:(NSError *)error
                guid:(NSString *)guid
    threadIdentifier:(NSString *)threadIdentifier;
- (void)setExpressiveSendStyleID:(NSString *)styleID;
- (void)setSubject:(NSString *)subject;
- (void)setMessageSubject:(NSAttributedString *)subject;
- (void)setThreadIdentifier:(NSString *)threadIdentifier;
- (void)setThreadOriginator:(id)originator;
- (void)setReplyToGUID:(NSString *)guid;
- (void)setBalloonBundleID:(NSString *)bundleID;
- (void)setPayloadData:(NSData *)data;
- (void)setAssociatedMessageGUID:(NSString *)guid;
- (void)setAssociatedMessageType:(long long)type;
- (void)setAssociatedMessageRange:(NSRange)range;
- (void)setMessageSummaryInfo:(NSDictionary *)info;
@end

@interface IMMessagePartChatItem : NSObject
- (NSInteger)index;
- (NSAttributedString *)text;
- (NSRange)messagePartRange;
@end

@interface IMAggregateAttachmentMessagePartChatItem : NSObject
- (NSArray *)aggregateAttachmentParts;
@end

@interface IMFileTransfer : NSObject
- (NSString *)guid;
- (NSString *)localPath;
- (NSString *)transferState;
- (NSURL *)localURL;
- (void)setLocalURL:(NSURL *)url;
@end

@interface IMFileTransferCenter : NSObject
+ (instancetype)sharedInstance;
- (NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url;
- (IMFileTransfer *)transferForGUID:(NSString *)guid;
- (void)retargetTransfer:(NSString *)guid toPath:(NSString *)path;
- (void)registerTransferWithDaemon:(NSString *)guid;
@end

typedef NS_ENUM(NSInteger, IMsgOutgoingTransferKind) {
    IMsgOutgoingTransferKindAttachment = 0,
    IMsgOutgoingTransferKindSticker = 1,
    IMsgOutgoingTransferKindRichLinkPreview = 2,
};

static IMFileTransfer *prepareOutgoingTransfer(NSURL *originalURL, NSString *filename,
                                               NSString *chatGuid,
                                               IMsgOutgoingTransferKind transferKind,
                                               NSDictionary *transferMetadata,
                                               NSString **outActivePath,
                                               NSString **outErr);
static IMFileTransfer *prepareUnregisteredOutgoingTransfer(
    NSURL *originalURL, NSString *filename, NSString *chatGuid,
    BOOL hideAttachment, NSString *mimeType, NSString **outErr);
static BOOL registerPreparedTransfer(IMFileTransfer *transfer, NSString **outErr);
static BOOL configurePreviewPayloadTransfer(IMFileTransfer *transfer,
                                            NSString *mimeType,
                                            NSString *filename);
static BOOL richLinkIntegerNumber(NSNumber *number);
static NSAttributedString *annotateBodyForRichLink(NSAttributedString *body,
                                                   NSString *urlString);

@interface IMDPersistentAttachmentController : NSObject
+ (instancetype)sharedInstance;
- (NSString *)_persistentPathForTransfer:(IMFileTransfer *)transfer
                                filename:(NSString *)filename
                             highQuality:(BOOL)highQuality
                                chatGUID:(NSString *)chatGUID
                     storeAtExternalPath:(BOOL)external;
@end

@interface IMChatHistoryController : NSObject
+ (instancetype)sharedInstance;
- (void)loadedChatItemsForChat:(IMChat *)chat
                    beforeDate:(NSDate *)date
                         limit:(NSUInteger)limit
                  loadIfNeeded:(BOOL)load;
- (void)loadMessageWithGUID:(NSString *)guid
            completionBlock:(void (^)(id message))completion;
@end

@interface IMNicknameController : NSObject
+ (instancetype)sharedInstance;
- (id)personalNickname;
- (BOOL)isInitialLoadComplete;
- (id)nicknameForHandle:(IMHandle *)handle;
- (BOOL)shouldOfferNicknameSharingForChat:(IMChat *)chat;
- (void)allowHandlesForNicknameSharing:(NSArray *)handles
                               forChat:(IMChat *)chat
                            fromHandle:(NSString *)fromHandleID
                             forceSend:(BOOL)forceSend;
@end

@interface IDSIDQueryController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedController;
- (NSInteger)_currentIDStatusForDestination:(NSString *)destination
                                    service:(NSString *)service
                                 listenerID:(NSString *)listenerID;
- (id)currentIDStatusForDestination:(NSString *)destination service:(id)service;
@end

#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

static NSString *serviceNameForChat(IMChat *chat, NSString *chatGuid) {
    NSString *serviceName = nil;
    if ([chat respondsToSelector:@selector(account)]) {
        id account = [chat performSelector:@selector(account)];
        if ([account respondsToSelector:@selector(serviceName)]) {
            serviceName = [account performSelector:@selector(serviceName)];
        }
    }
    if (serviceName.length) return serviceName;
    if ([chatGuid hasPrefix:@"SMS;"]) return @"SMS";
    if ([chatGuid hasPrefix:@"iMessage;"]) return @"iMessage";
    if ([chatGuid hasPrefix:@"iMessageLite;"]) return @"iMessageLite";
    return nil;
}

static NSArray *handlesFromCandidate(id candidate) {
    NSMutableArray *handles = [NSMutableArray array];
    if ([candidate isKindOfClass:[NSArray class]]) {
        [handles addObjectsFromArray:candidate];
    } else if ([candidate isKindOfClass:[NSSet class]]) {
        [handles addObjectsFromArray:[candidate allObjects]];
    } else if (candidate) {
        [handles addObject:candidate];
    }
    return handles;
}

static id handleMatchingService(NSArray *handles, NSString *preferredService) {
    for (id handle in handles) {
        if (![handle respondsToSelector:@selector(serviceName)]) continue;
        NSString *serviceName = [handle performSelector:@selector(serviceName)];
        if ([serviceName isKindOfClass:[NSString class]] &&
            [serviceName caseInsensitiveCompare:preferredService ?: @""] == NSOrderedSame) {
            return handle;
        }
    }
    return nil;
}

static id vendIMHandle(id registrar, NSString *address, NSString *preferredService, BOOL allowFallback) {
    if (!registrar || ![address isKindOfClass:[NSString class]] || address.length == 0) {
        return nil;
    }

    NSMutableArray *fallbackHandles = [NSMutableArray array];
    @try {
        if ([registrar respondsToSelector:@selector(IMHandleWithID:)]) {
            NSArray *handles = handlesFromCandidate([registrar performSelector:@selector(IMHandleWithID:)
                                                                       withObject:address]);
            id handle = handleMatchingService(handles, preferredService);
            if (handle) return handle;
            [fallbackHandles addObjectsFromArray:handles];
        }
        if ([registrar respondsToSelector:@selector(getIMHandlesForID:)]) {
            NSArray *handles = handlesFromCandidate([registrar performSelector:@selector(getIMHandlesForID:)
                                                                       withObject:address]);
            id handle = handleMatchingService(handles, preferredService);
            if (handle) return handle;
            [fallbackHandles addObjectsFromArray:handles];
        }
    } @catch (__unused NSException *ex) {
        return nil;
    }
    return allowFallback ? fallbackHandles.firstObject : nil;
}

#pragma mark - Chat Resolution

static NSArray<NSString *>* chatIdentifierPrefixes(void) {
    return @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;", @"any;-;", @"any;+;"];
}

static NSString* stripKnownChatPrefix(NSString *value) {
    for (NSString *prefix in chatIdentifierPrefixes()) {
        if ([value hasPrefix:prefix]) {
            return [value substringFromIndex:prefix.length];
        }
    }
    return nil;
}

/// Try multiple methods to find a chat, including GUID lookup, chat identifier,
/// and participant matching with phone number normalization.
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-bridge] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-bridge] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;
    NSString *bareIdentifier = stripKnownChatPrefix(identifier) ?: identifier;

    // Method 1: Try existingChatWithGUID: with the identifier as-is (if it looks like a GUID)
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes (iMessage, SMS, any)
        for (NSString *prefix in chatIdentifierPrefixes()) {
            NSString *fullGUID = [prefix stringByAppendingString:bareIdentifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
        if (![bareIdentifier isEqualToString:identifier]) {
            chat = [registry performSelector:identSel withObject:bareIdentifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", bareIdentifier);
                return chat;
            }
        }
    }

    // Method 3: Iterate all chats and match by participant
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) {
            NSLog(@"[imsg-bridge] allExistingChats returned nil");
            return nil;
        }
        NSLog(@"[imsg-bridge] Searching %lu chats for identifier: %@",
              (unsigned long)allChats.count, identifier);

        // Normalize the search identifier for phone number matching
        NSString *normalizedIdentifier = nil;
        if (bareIdentifier.length > 0 &&
            ([bareIdentifier hasPrefix:@"+"] || [bareIdentifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet]
             characterIsMember:[bareIdentifier characterAtIndex:0]])) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < bareIdentifier.length; i++) {
                unichar c = [bareIdentifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier] ||
                    [chatGUID isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier] ||
                    [chatId isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                if (!participants) continue;
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        if ([handleID isEqualToString:identifier] ||
                            [handleID isEqualToString:bareIdentifier]) {
                            NSLog(@"[imsg-bridge] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                ([handleDigits hasSuffix:normalizedIdentifier] ||
                                 [normalizedIdentifier hasSuffix:handleDigits])) {
                                NSLog(@"[imsg-bridge] Found chat by normalized phone match: %@ ~ %@",
                                      handleID, identifier);
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-bridge] Chat not found for identifier: %@", identifier);
    return nil;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];
    debugLog(@"handleTyping: enter handle=%@ state=%@ params=%@", handle, state, params);

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        debugLog(@"handleTyping: chat not found for %@", handle);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Gather diagnostic info
        NSString *chatGUID = @"unknown";
        NSString *chatIdent = @"unknown";
        NSString *chatClass = NSStringFromClass([chat class]);
        BOOL supportsTyping = YES;

        if ([chat respondsToSelector:@selector(guid)]) {
            chatGUID = [chat performSelector:@selector(guid)] ?: @"nil";
        }
        if ([chat respondsToSelector:@selector(chatIdentifier)]) {
            chatIdent = [chat performSelector:@selector(chatIdentifier)] ?: @"nil";
        }

        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
        }

        BOOL isCurrentlyTyping = NO;
        if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
            isCurrentlyTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
        }

        id account = nil;
        NSString *acctService = @"nil";
        BOOL acctActive = NO;
        BOOL acctLoggedIn = NO;
        if ([chat respondsToSelector:@selector(account)]) {
            account = [chat performSelector:@selector(account)];
            if ([account respondsToSelector:@selector(serviceName)]) {
                acctService = [account performSelector:@selector(serviceName)] ?: @"nil";
            }
            if ([account respondsToSelector:@selector(isActive)]) {
                acctActive = ((BOOL (*)(id, SEL))objc_msgSend)(account, @selector(isActive));
            }
            if ([account respondsToSelector:@selector(loggedIn)]) {
                acctLoggedIn = ((BOOL (*)(id, SEL))objc_msgSend)(account, @selector(loggedIn));
            }
        }

        debugLog(@"handleTyping: chat class=%@ guid=%@ ident=%@ supportsTyping=%d alreadyTyping=%d "
                 @"acctService=%@ acctActive=%d acctLoggedIn=%d target=%d",
                 chatClass, chatGUID, chatIdent, supportsTyping, isCurrentlyTyping,
                 acctService, acctActive, acctLoggedIn, typing);

        NSLog(@"[imsg-bridge] Chat found: class=%@, guid=%@, identifier=%@, supportsTyping=%@",
              chatClass, chatGUID, chatIdent, supportsTyping ? @"YES" : @"NO");

        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            if (!sig) {
                return errorResponse(requestId,
                    @"Could not get method signature for setLocalUserIsTyping:");
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            BOOL afterTyping = NO;
            if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
                afterTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
            }
            debugLog(@"handleTyping: setLocalUserIsTyping:%d returned, isCurrentlyTyping after=%d",
                     typing, afterTyping);

            NSLog(@"[imsg-bridge] Called setLocalUserIsTyping:%@ for %@",
                  typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing)
            });
        }

        debugLog(@"handleTyping: setLocalUserIsTyping: not available on chat class=%@", chatClass);
        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        debugLog(@"handleTyping: exception=%@", exception.reason);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    debugLog(@"handleRead: enter handle=%@ params=%@", handle, params);

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        debugLog(@"handleRead: chat not found for %@", handle);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    NSString *chatClass = NSStringFromClass([chat class]);
    NSUInteger unreadBefore = 0;
    BOOL hadUnread = NO;
    if ([chat respondsToSelector:@selector(unreadMessageCount)]) {
        unreadBefore = ((NSUInteger (*)(id, SEL))objc_msgSend)(chat, @selector(unreadMessageCount));
    }
    if ([chat respondsToSelector:@selector(hasUnreadMessages)]) {
        hadUnread = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(hasUnreadMessages));
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        debugLog(@"handleRead: chat class=%@ unreadBefore=%lu hasUnread=%d responds=%d",
                 chatClass, (unsigned long)unreadBefore, hadUnread,
                 [chat respondsToSelector:readSel]);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSUInteger unreadAfter = 0;
            BOOL hasUnreadAfter = NO;
            if ([chat respondsToSelector:@selector(unreadMessageCount)]) {
                unreadAfter = ((NSUInteger (*)(id, SEL))objc_msgSend)(chat, @selector(unreadMessageCount));
            }
            if ([chat respondsToSelector:@selector(hasUnreadMessages)]) {
                hasUnreadAfter = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(hasUnreadMessages));
            }
            debugLog(@"handleRead: markAllMessagesAsRead returned, unreadAfter=%lu hasUnreadAfter=%d",
                     (unsigned long)unreadAfter, hasUnreadAfter);
            NSLog(@"[imsg-bridge] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        debugLog(@"handleRead: exception=%@", exception.reason);
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

static BOOL stickerAttachmentMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    return [messageClass instancesRespondToSelector:NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:")]
        || [messageClass instancesRespondToSelector:NSSelectorFromString(
            @"initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:")];
}

static BOOL stickerAssociatedMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    return [messageClass instancesRespondToSelector:NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:")]
        || [messageClass instancesRespondToSelector:NSSelectorFromString(
            @"initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:")];
}

static BOOL stickerTransferSelectorsAvailable(void) {
    Class transferClass = NSClassFromString(@"IMFileTransfer");
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    return [transferClass instancesRespondToSelector:NSSelectorFromString(@"setIsSticker:")]
        && [transferClass instancesRespondToSelector:NSSelectorFromString(@"setStickerUserInfo:")]
        && [transferClass instancesRespondToSelector:NSSelectorFromString(@"setAttributionInfo:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(
            @"guidForNewOutgoingTransferWithLocalURL:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(@"transferForGUID:")]
        && [centerClass instancesRespondToSelector:NSSelectorFromString(
            @"registerTransferWithDaemon:")];
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    NSDictionary *nicknameSelectors = nicknameSharingSelectorStatus();
    Class stickerTransferClass = NSClassFromString(@"IMFileTransfer");
    Class transferCenterClass = NSClassFromString(@"IMFileTransferCenter");
    BOOL stickerSetIsSticker = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setIsSticker:")];
    BOOL stickerSetUserInfo = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setStickerUserInfo:")];
    BOOL stickerSetAttribution = [stickerTransferClass instancesRespondToSelector:
        NSSelectorFromString(@"setAttributionInfo:")];
    BOOL stickerTransferCenter =
        [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"guidForNewOutgoingTransferWithLocalURL:")]
        && [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"transferForGUID:")]
        && [transferCenterClass instancesRespondToSelector:
            NSSelectorFromString(@"registerTransferWithDaemon:")];
    BOOL stickerReplyTo = [NSClassFromString(@"IMMessage")
        instancesRespondToSelector:NSSelectorFromString(@"setReplyToGUID:")];
    BOOL stickerTargetMembership = [NSClassFromString(@"IMChat")
        instancesRespondToSelector:NSSelectorFromString(@"hasStoredMessageWithGUID:")];
    BOOL stickerTargetLookup = [NSClassFromString(@"IMChatHistoryController")
        instancesRespondToSelector:NSSelectorFromString(
            @"loadMessageWithGUID:completionBlock:")]
        && [NSClassFromString(@"IMMessage")
            instancesRespondToSelector:NSSelectorFromString(@"_imMessageItem")]
        && [NSClassFromString(@"IMMessageItem")
            instancesRespondToSelector:NSSelectorFromString(@"_newChatItems")]
        && [NSClassFromString(@"IMMessagePartChatItem")
            instancesRespondToSelector:NSSelectorFromString(@"index")]
        && [NSClassFromString(@"IMMessagePartChatItem")
            instancesRespondToSelector:NSSelectorFromString(@"messagePartRange")];
    BOOL stickerAttachmentMessage = stickerAttachmentMessageInitializerAvailable();
    BOOL stickerAssociatedMessage = stickerAssociatedMessageInitializerAvailable();
    BOOL stickerSend = stickerSetIsSticker && stickerSetUserInfo
        && stickerSetAttribution && stickerTransferCenter && stickerAttachmentMessage;
    NSDictionary *selectors = @{
        @"editMessageItem": @(gHasEditMessageItem),
        @"editMessage": @(gHasEditMessage),
        @"retractMessagePart": @(gHasRetractMessagePart),
        @"sendMessageReason": @(gHasSendMessageReason),
        @"pollPayloadMessage": @(pollPayloadMessageInitializerAvailable()),
        @"pollVoteMessage": @(pollVoteMessageInitializerAvailable()),
        @"nicknameLookup": nicknameSelectors[@"nickname_lookup"],
        @"namePhotoShouldOffer": nicknameSelectors[@"should_offer"],
        @"namePhotoShare": nicknameSelectors[@"share"],
        @"stickerSetIsSticker": @(stickerSetIsSticker),
        @"stickerSetUserInfo": @(stickerSetUserInfo),
        @"stickerSetAttribution": @(stickerSetAttribution),
        @"stickerTransferCenter": @(stickerTransferCenter),
        @"stickerReplyTo": @(stickerReplyTo),
        @"stickerTargetMembership": @(stickerTargetMembership),
        @"stickerTargetLookup": @(stickerTargetLookup),
        @"stickerAttachmentMessage": @(stickerAttachmentMessage),
        @"stickerAssociatedMessage": @(stickerAssociatedMessage),
        @"stickerSend": @(stickerSend),
        @"stickerAttach": @(
            stickerSend && stickerTargetMembership && stickerTargetLookup
                && stickerAssociatedMessage),
        @"urlPreviewMessage": @(urlPreviewMessageInitializerAvailable()),
        @"sendRichLinkAction": @YES,
        @"pollUpdateMessage": @(pollVoteMessageInitializerAvailable()),
        @"deleteChat": @(hasRegistry &&
            [registryClass instancesRespondToSelector:NSSelectorFromString(@"deleteChat:")]),
        @"removeChat": @(hasRegistry &&
            [registryClass instancesRespondToSelector:NSSelectorFromString(@"_chat_remove:")])
    };

    return successResponse(requestId, @{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"bridge_version": @2,
        @"v2_ready": @(rpcInboxTimer != nil),
        @"attachment_metadata": @YES,
        @"selectors": selectors
    });
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

#pragma mark - Resolve Chat (v2)

/// Resolve an IMChat from a chatGuid string (BlueBubbles-style addressing,
/// e.g. `iMessage;-;+15551234567` or `iMessage;+;chat0000`). Falls back to
/// `chatForIMHandle:` to materialize chats that don't yet exist in the
/// registry's allExistingChats snapshot. Returns nil if no chat could be
/// resolved or created.
static IMChat *resolveChatByGuid(NSString *chatGuid) {
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return nil;
    }
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return nil;
    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) return nil;

    if ([registry respondsToSelector:@selector(existingChatWithGUID:)]) {
        id chat = [registry performSelector:@selector(existingChatWithGUID:)
                                 withObject:chatGuid];
        if (chat) return chat;
    }

    // Fallback: parse a direct `<service>;-;<address>` guid and materialize
    // a chat using only a handle for the explicitly requested service.
    NSArray *parts = [chatGuid componentsSeparatedByString:@";"];
    if (parts.count == 3 && [parts[1] isEqualToString:@"-"]) {
        NSString *preferredService = parts.firstObject;
        NSString *address = parts.lastObject;
        Class hrClass = NSClassFromString(@"IMHandleRegistrar");
        if (hrClass) {
            id hr = [hrClass performSelector:@selector(sharedInstance)];
            id handle = vendIMHandle(hr, address, preferredService, NO);
            if (handle && [registry respondsToSelector:@selector(chatForIMHandle:)]) {
                id chat = [registry performSelector:@selector(chatForIMHandle:)
                                         withObject:handle];
                if (chat) return chat;
            }
        }
    }
    return nil;
}

/// Resolve a chat by EITHER chatGuid (preferred) OR a free-form handle
/// (legacy path that walks `findChat`). Used to keep existing callers working.
static id resolveChatFlexible(NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if ([chatGuid isKindOfClass:[NSString class]] && chatGuid.length) {
        IMChat *chat = resolveChatByGuid(chatGuid);
        if (chat) return chat;
    }
    NSString *handle = params[@"handle"];
    if ([handle isKindOfClass:[NSString class]] && handle.length) {
        return findChat(handle);
    }
    return nil;
}

#pragma mark - AttributedBody Helpers

/// Decode a base64 NSKeyedArchiver blob into an NSAttributedString. Returns
/// nil on any decoding failure.
static NSAttributedString *attributedBodyFromBase64(NSString *b64) {
    if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) return nil;
    NSError *err = nil;
    NSSet *allowed = [NSSet setWithObjects:
        [NSAttributedString class], [NSDictionary class], [NSString class],
        [NSArray class], [NSNumber class], [NSURL class], [NSData class], nil];
    NSAttributedString *attr = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed
                                                                   fromData:data
                                                                      error:&err];
    if (err) {
        // Fall back to non-secure unarchiving for older blobs.
        @try {
            attr = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        } @catch (__unused NSException *ex) {
            attr = nil;
        }
    }
    return attr;
}

/// Build a plain NSAttributedString carrying `text` as message-part `partIndex`.
/// Applies the private `__kIMMessagePartAttributeName` attribute IMCore expects.
static NSAttributedString *buildPlainAttributed(NSString *text, NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSDictionary *attrs = @{
        @"__kIMMessagePartAttributeName": @(partIndex),
        @"__kIMBaseWritingDirectionAttributeName": @"-1"
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

static NSAttributedString *buildPollBreadcrumbAttributed(void) {
    NSString *placeholder = [NSString stringWithFormat:@"%C", (unichar)0xFFFD];
    NSDictionary *attrs = @{
        @"__kIMMessagePartAttributeName": @0,
        @"__kIMBreadcrumbTextMarkerAttributeName": @"Sent a poll",
        @"__kIMBreadcrumbTextOptionFlags": @0
    };
    return [[NSAttributedString alloc] initWithString:placeholder attributes:attrs];
}

/// Apply a JSON-shape array of text-formatting ranges to `text`. Each entry is
/// `{ "start": int, "length": int, "styles": ["bold"|"italic"|"underline"|"strikethrough", ...] }`.
/// macOS 15+ only — earlier OSes silently degrade to plain text (the private
/// IMText* attribute names don't exist before Sequoia). Attribute names and
/// range shape are based on BlueBubbles helper PR #50; implementation is local.
static NSMutableAttributedString *buildFormattedAttributed(NSString *text,
                                                            NSArray *formatting,
                                                            NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text];
    NSUInteger len = text.length;

    // Always carry the same base IM attributes as plain sends across the
    // whole string, then layer style ranges on top when supported.
    if (len > 0) {
        [attr addAttribute:@"__kIMMessagePartAttributeName" value:@(partIndex)
                     range:NSMakeRange(0, len)];
        [attr addAttribute:@"__kIMBaseWritingDirectionAttributeName" value:@"-1"
                     range:NSMakeRange(0, len)];
    }

    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 15) {
        return attr;  // Pre-Sequoia: no IMText* attributes; ship plain.
    }
    if (len == 0 || ![formatting isKindOfClass:[NSArray class]] || formatting.count == 0) {
        return attr;
    }

    for (id raw in formatting) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = (NSDictionary *)raw;
        NSNumber *startNum = r[@"start"];
        NSNumber *lengthNum = r[@"length"];
        NSArray *styles = r[@"styles"];
        if (![startNum isKindOfClass:[NSNumber class]]) continue;
        if (![lengthNum isKindOfClass:[NSNumber class]]) continue;
        if (![styles isKindOfClass:[NSArray class]]) continue;
        NSInteger start = startNum.integerValue;
        NSInteger length = lengthNum.integerValue;
        if (start < 0 || length <= 0) continue;
        if ((NSUInteger)(start + length) > len) continue;

        NSRange range = NSMakeRange((NSUInteger)start, (NSUInteger)length);
        if ([styles containsObject:@"bold"]) {
            [attr addAttribute:@"__kIMTextBoldAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"italic"]) {
            [attr addAttribute:@"__kIMTextItalicAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"underline"]) {
            [attr addAttribute:@"__kIMTextUnderlineAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"strikethrough"]) {
            [attr addAttribute:@"__kIMTextStrikethroughAttributeName" value:@1 range:range];
        }
    }
    return attr;
}

#pragma mark - IMMessage Builder

/// Invoke a class method that returns an object, returning a strongly
/// retained id. NSInvocation returns object references without transferring
/// ownership, so we read into an `__unsafe_unretained` slot then assign to a
/// strong variable to balance ARC.
static id invokeReturningObject(NSInvocation *inv) {
    __unsafe_unretained id raw = nil;
    [inv invoke];
    [inv getReturnValue:&raw];
    return raw;
}

/// Apply optional metadata fields directly onto the IMMessageItem before
/// the IMMessage wrap. Setters on a wrapped IMMessage's `_imMessageItem`
/// don't persist (the wrap returns a transient item rebuilt each call), so
/// extended fields like `expressiveSendStyleID` and `associatedMessageGUID`
/// must be applied here, ahead of the wrap.
static void applyItemExtendedFields(id item,
                                    NSAttributedString *subject,
                                    NSString *effectId,
                                    NSString *associatedMessageGuid,
                                    long long associatedMessageType,
                                    NSRange associatedMessageRange,
                                    NSDictionary *summaryInfo) {
    if (!item) return;
    if (subject.length
        && [item respondsToSelector:@selector(setMessageSubject:)]) {
        [item performSelector:@selector(setMessageSubject:) withObject:subject];
    }
    if (effectId.length
        && [item respondsToSelector:@selector(setExpressiveSendStyleID:)]) {
        [item performSelector:@selector(setExpressiveSendStyleID:)
                   withObject:effectId];
    }
    if (associatedMessageGuid.length && associatedMessageType > 0) {
        if ([item respondsToSelector:@selector(setAssociatedMessageGUID:)]) {
            [item performSelector:@selector(setAssociatedMessageGUID:)
                       withObject:associatedMessageGuid];
        }
        if ([item respondsToSelector:@selector(setAssociatedMessageType:)]) {
            NSMethodSignature *sig = [item methodSignatureForSelector:
                @selector(setAssociatedMessageType:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setAssociatedMessageType:)];
            [inv setTarget:item];
            [inv setArgument:&associatedMessageType atIndex:2];
            [inv invoke];
        }
        if ([item respondsToSelector:@selector(setAssociatedMessageRange:)]) {
            NSMethodSignature *sig = [item methodSignatureForSelector:
                @selector(setAssociatedMessageRange:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setAssociatedMessageRange:)];
            [inv setTarget:item];
            NSRange range = associatedMessageRange;
            [inv setArgument:&range atIndex:2];
            [inv invoke];
        }
    }
    if (summaryInfo
        && [item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
        [item performSelector:@selector(setMessageSummaryInfo:)
                   withObject:summaryInfo];
    }
}

static void ensureItemBodyData(id item, NSAttributedString *attributedText) {
    if (!item || attributedText.length == 0) return;
    NSData *bodyData = [item respondsToSelector:@selector(bodyData)]
        ? [item performSelector:@selector(bodyData)] : nil;
    if (bodyData.length > 0 || ![item respondsToSelector:@selector(setBodyData:)]) {
        return;
    }

    @try {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSData *typedstream = [NSArchiver archivedDataWithRootObject:attributedText];
        #pragma clang diagnostic pop
        if (typedstream.length > 0) {
            [item performSelector:@selector(setBodyData:) withObject:typedstream];
        }
    } @catch (NSException *e) {
        // NSArchiver chokes on NSPresentationIntent attributes that some
        // markdown initializers emit. Retry with a plain copy.
        NSMutableAttributedString *plain = [[NSMutableAttributedString alloc]
            initWithString:[attributedText string]];
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSData *plainData = [NSArchiver archivedDataWithRootObject:plain];
            #pragma clang diagnostic pop
            [item performSelector:@selector(setBodyData:) withObject:plainData];
        } @catch (__unused NSException *e2) {
            // Give up; the wrap below may still succeed for non-empty cases.
        }
    }
}

static void clearReplyMetadataOnObject(id object) {
    if (!object) return;
    NSArray<NSString *> *objectSelectors = @[
        @"setReplyToGUID:",
        @"setThreadIdentifier:",
        @"setThreadOriginator:",
        @"setThreadOriginatorGUID:",
        @"setThreadOriginatorPart:"
    ];
    id nilObject = nil;
    for (NSString *selectorName in objectSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector]) {
            @try {
                [object performSelector:selector withObject:nilObject];
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL associatedTypeSelector = @selector(setAssociatedMessageType:);
    if ([object respondsToSelector:associatedTypeSelector]) {
        @try {
            NSMethodSignature *sig =
                [object methodSignatureForSelector:associatedTypeSelector];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:associatedTypeSelector];
            [inv setTarget:object];
            long long zero = 0;
            [inv setArgument:&zero atIndex:2];
            [inv invoke];
        } @catch (__unused NSException *exception) {}
    }
    SEL associatedGuidSelector = @selector(setAssociatedMessageGUID:);
    if ([object respondsToSelector:associatedGuidSelector]) {
        @try {
            [object performSelector:associatedGuidSelector withObject:nilObject];
        } @catch (__unused NSException *exception) {}
    }
}

static void clearReplyMetadataOnMessage(id message) {
    clearReplyMetadataOnObject(message);
    SEL itemSel = NSSelectorFromString(@"_imMessageItem");
    if ([message respondsToSelector:itemSel]) {
        @try {
            id item = [message performSelector:itemSel];
            clearReplyMetadataOnObject(item);
        } @catch (__unused NSException *exception) {}
    }
}

/// Build an IMMessageItem with the body set up-front, apply any extended
/// metadata fields onto the item, then wrap with IMMessage. On macOS 26 the
/// high-level `+initIMMessageWith…` factories build a transient
/// IMMessageItem on demand whose `body` / `bodyData` don't survive
/// `[chat sendMessage:]` — imagent reads `bodyData` from the underlying
/// item, sees nothing, and silently drops the message. Building the item
/// up-front and seeding `bodyData` via NSArchiver is the only path that
/// lands on macOS 26. Returns nil if the required selectors are missing
/// (older OSes; caller should fall back).
static id constructIMMessageViaItem(NSAttributedString *attributedText,
                                    NSAttributedString *subject,
                                    NSString *effectId,
                                    NSString *threadIdentifier,
                                    id threadOriginator,
                                    NSString *associatedMessageGuid,
                                    long long associatedMessageType,
                                    NSRange associatedMessageRange,
                                    NSDictionary *summaryInfo,
                                    NSArray *fileTransferGuids,
                                    BOOL isAudioMessage) {
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (!IMMessageClass || !IMMessageItemClass) return nil;

    SEL itemInitSel = @selector(initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:);
    if (![IMMessageItemClass instancesRespondToSelector:itemInitSel]) return nil;

    SEL wrapSel = @selector(messageFromIMMessageItem:sender:subject:);
    if (![IMMessageClass respondsToSelector:wrapSel]) return nil;

    id item = [IMMessageItemClass alloc];
    if (!item) return nil;

    NSDate *now = [NSDate date];
    NSArray *transferGuids = fileTransferGuids ?: @[];
    NSError *err = nil;
    NSString *guid = [[NSUUID UUID] UUIDString];
    // BlueBubblesHelper-verified flag set: 0x100005 (FromMe | Finished |
    // 0x100000 finalize bit) for normal text+attachment, 0x10000d when a
    // subject is set, 0x300005 for audio messages. The earlier `0x5`
    // variant was the cause of malformed attachments on the receiver — the
    // 0x100000 bit is what tells imagent to finalize the payload.
    unsigned long long flags;
    if (isAudioMessage) {
        flags = 0x300005ULL;
    } else if (subject.length) {
        flags = 0x10000dULL;
    } else {
        flags = 0x100005ULL;
    }
    id sender = nil;
    NSDictionary *attributes = nil;
    NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

    NSMethodSignature *isig =
        [IMMessageItemClass instanceMethodSignatureForSelector:itemInitSel];
    NSInvocation *iinv = [NSInvocation invocationWithMethodSignature:isig];
    [iinv setSelector:itemInitSel];
    [iinv setTarget:item];
    [iinv setArgument:&sender atIndex:2];
    [iinv setArgument:&now atIndex:3];
    [iinv setArgument:&attributedText atIndex:4];
    [iinv setArgument:&attributes atIndex:5];
    [iinv setArgument:&transferGuids atIndex:6];
    [iinv setArgument:&flags atIndex:7];
    [iinv setArgument:&err atIndex:8];
    [iinv setArgument:&guid atIndex:9];
    [iinv setArgument:&messageThreadIdentifier atIndex:10];
    [iinv retainArguments];
    item = invokeReturningObject(iinv);
    if (!item) return nil;

    if ([item respondsToSelector:@selector(_regenerateBodyData)]) {
        [item performSelector:@selector(_regenerateBodyData)];
    }

    // imagent reads bodyData (NSArchiver typedstream). On macOS 26 the
    // initWithSender: path leaves bodyData empty; force-archive the
    // attributed string ourselves so the daemon has a payload to ship.
    ensureItemBodyData(item, attributedText);

    // Set extended fields on the item BEFORE wrapping. The IMMessage wrap's
    // `_imMessageItem` accessor returns a transient item rebuilt each call,
    // so post-wrap setters don't persist (per the macOS 26 behavior 10ce6ab
    // documented).
    applyItemExtendedFields(item, subject, effectId,
                            associatedMessageGuid, associatedMessageType,
                            associatedMessageRange, summaryInfo);
    BOOL standalone = !threadIdentifier.length
        && !threadOriginator
        && !associatedMessageGuid.length
        && associatedMessageType == 0;
    if (standalone) {
        clearReplyMetadataOnObject(item);
    }
    if (threadOriginator
        && [item respondsToSelector:@selector(setThreadOriginator:)]) {
        [item performSelector:@selector(setThreadOriginator:)
                   withObject:threadOriginator];
    }

    NSMethodSignature *wsig =
        [IMMessageClass methodSignatureForSelector:wrapSel];
    NSInvocation *winv = [NSInvocation invocationWithMethodSignature:wsig];
    [winv setSelector:wrapSel];
    [winv setTarget:IMMessageClass];
    id nilSender = nil;
    id nilSubject = nil;
    [winv setArgument:&item atIndex:2];
    [winv setArgument:&nilSender atIndex:3];
    [winv setArgument:&nilSubject atIndex:4];
    [winv retainArguments];
    id result = invokeReturningObject(winv);
    if (standalone) {
        clearReplyMetadataOnMessage(result);
    }
    return result;
}

/// Load the parent message for a reply via IMChatHistoryController and derive
/// the thread identifier Messages uses for native inline replies. This follows
/// the BlueBubbles IMCore shape: reuse the parent's existing thread identifier
/// when present, otherwise derive one from the matching message-part chat item.
static NSString *deriveThreadIdentifier(NSString *parentGuid,
                                         id *outParentMessage,
                                         id *outParentItem) {
    if (outParentMessage) *outParentMessage = nil;
    if (outParentItem) *outParentItem = nil;
    if (parentGuid.length == 0) return nil;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    if (!hcClass) {
        debugLog(@"deriveThreadIdentifier: IMChatHistoryController class missing");
        return nil;
    }
    id hc = [hcClass performSelector:@selector(sharedInstance)];
    if (!hc) {
        debugLog(@"deriveThreadIdentifier: sharedInstance returned nil");
        return nil;
    }
    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![hc respondsToSelector:loadSel]) {
        debugLog(@"deriveThreadIdentifier: loadMessageWithGUID:completionBlock: missing");
        return nil;
    }

    __block id parent = nil;
    __block BOOL done = NO;
    NSMethodSignature *sig = [hc methodSignatureForSelector:loadSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:loadSel];
    [inv setTarget:hc];
    NSString *guid = parentGuid;
    [inv setArgument:&guid atIndex:2];
    void (^completion)(id) = ^(id message) {
        parent = message;
        done = YES;
    };
    [inv setArgument:&completion atIndex:3];
    [inv retainArguments];
    [inv invoke];

    // Pump the run loop briefly so the load completion can run inline.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!parent) {
        debugLog(@"deriveThreadIdentifier: parent did not load within 3s for %@",
                 parentGuid);
        return nil;
    }
    if (outParentMessage) *outParentMessage = parent;

    if (![parent respondsToSelector:@selector(_imMessageItem)]) {
        debugLog(@"deriveThreadIdentifier: parent has no _imMessageItem");
        return nil;
    }
    id parentItem = [parent performSelector:@selector(_imMessageItem)];
    if (outParentItem) *outParentItem = parentItem;

    SEL chatItemsSel = NSSelectorFromString(@"_newChatItems");
    if (!parentItem || ![parentItem respondsToSelector:chatItemsSel]) {
        debugLog(@"deriveThreadIdentifier: parentItem missing _newChatItems");
        return nil;
    }

    id items = [parentItem performSelector:chatItemsSel];
    id chatItem = nil;
    if ([items isKindOfClass:[NSArray class]]) {
        SEL backingItemSel = NSSelectorFromString(@"_item");
        for (id candidate in (NSArray *)items) {
            id backingItem = [candidate respondsToSelector:backingItemSel]
                ? [candidate performSelector:backingItemSel] : nil;
            NSString *candidateGuid = nil;
            if ([backingItem respondsToSelector:@selector(guid)]) {
                candidateGuid = [backingItem performSelector:@selector(guid)];
            } else if ([candidate respondsToSelector:@selector(guid)]) {
                candidateGuid = [candidate performSelector:@selector(guid)];
            }
            if ([candidateGuid isEqualToString:parentGuid]) {
                chatItem = candidate;
                break;
            }
        }
        if (!chatItem) {
            chatItem = [(NSArray *)items firstObject];
        }
    } else {
        chatItem = items;
    }
    if (!chatItem) {
        debugLog(@"deriveThreadIdentifier: parent has no chat items");
        return nil;
    }

    if ([parent respondsToSelector:@selector(threadIdentifier)]) {
        NSString *existingIdentifier =
            [parent performSelector:@selector(threadIdentifier)];
        if (existingIdentifier.length > 0) {
            debugLog(@"deriveThreadIdentifier: parent=%@ existing=%@",
                     parentGuid, existingIdentifier);
            return existingIdentifier;
        }
    }

    IMCreateThreadIdentifierForMessagePartChatItemFn fn =
        imCreateThreadIdentifierFn();
    if (!fn) {
        debugLog(@"deriveThreadIdentifier: IMCreateThreadIdentifier… symbol not found");
        return nil;
    }
    NSString *result = fn(chatItem);
    debugLog(@"deriveThreadIdentifier: parent=%@ result=%@",
             parentGuid, result ?: @"(nil)");
    return result;
}

/// Load the parent message via `IMChatHistoryController` and return its
/// first `IMMessagePartChatItem` plus the parent message itself. Used by
/// reactions to derive the canonical `associatedMessageRange` (BB-verified:
/// `[item messagePartRange]`, not a hardcoded `{0,1}`).
///
/// Block-based load semantics match `loadMessageWithGUID:completionBlock:`,
/// which `deriveThreadIdentifier` already drives. This helper duplicates
/// the load to keep the reply / reaction code paths independent (each
/// fires its own load), which is what BlueBubblesHelper does too — and
/// avoids gnarly out-parameter plumbing through deriveThreadIdentifier.
static id safelyReadObjectSelector(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        // Some Tahoe IMCore proxy objects claim private selectors through
        // forwarding, then raise unrecognized-selector when invoked.
        return nil;
    }
}

static id safelyReadObjectSelectorWithObject(id object, SEL selector, id argument) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id safelyReadObjectSelectorWithTwoObjects(id object, SEL selector,
                                                 id first, id second) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)(
            object, selector, first, second);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id normalizeFoundMessageItemWithChatContext(id object, id chatContext) {
    if (!object) return nil;

    Class partClass = NSClassFromString(@"IMMessagePartChatItem");
    if (partClass && [object isKindOfClass:partClass]) return object;

    // History loading can yield an IMMessage, its backing IMMessageItem, or
    // a chat item directly depending on OS version and whether it is a
    // threaded reply. Normalize all three to the chat item mutations expect.
    id messageItem = object;
    SEL itemSel = @selector(_imMessageItem);
    if ([messageItem respondsToSelector:itemSel]) {
        messageItem = safelyReadObjectSelector(messageItem, itemSel);
        if (!messageItem) return nil;
    }
    SEL chatItemsSel = @selector(_newChatItems);
    BOOL hasChatItemsSelector = [messageItem respondsToSelector:chatItemsSel];
    id items = nil;
    if (hasChatItemsSelector) {
        items = safelyReadObjectSelector(messageItem, chatItemsSel);
    }
    BOOL needsContext = !items
        || ([items isKindOfClass:[NSArray class]] && ((NSArray *)items).count == 0);
    if (needsContext && chatContext) {
        SEL contextSel = NSSelectorFromString(@"_newChatItemsWithChatContext:");
        items = safelyReadObjectSelectorWithObject(messageItem, contextSel, chatContext);
        BOOL contextItemsMissing = !items
            || ([items isKindOfClass:[NSArray class]] && ((NSArray *)items).count == 0);
        if (contextItemsMissing) {
            SEL partsSel = NSSelectorFromString(
                @"_newMessagePartsForMessageItem:chatContext:");
            items = safelyReadObjectSelectorWithTwoObjects(
                partClass, partsSel, messageItem, chatContext);
        }
    }
    if ([items isKindOfClass:[NSArray class]]) {
        return ((NSArray *)items).firstObject;
    }
    return items ?: (hasChatItemsSelector ? nil : messageItem);
}

static id normalizeFoundMessageItem(id object) {
    return normalizeFoundMessageItemWithChatContext(object, nil);
}

static id chatItemWithPartIndex(id candidate, NSInteger partIndex) {
    if ([candidate isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)candidate) {
            id match = chatItemWithPartIndex(item, partIndex);
            if (match) return match;
        }
        return nil;
    }
    id aggregate = safelyReadObjectSelector(
        candidate, @selector(aggregateAttachmentParts));
    id aggregateMatch = chatItemWithPartIndex(aggregate, partIndex);
    if (aggregateMatch) return aggregateMatch;
    if ([candidate respondsToSelector:@selector(index)]
        && [(IMMessagePartChatItem *)candidate index] == partIndex) {
        return candidate;
    }
    return nil;
}

static id loadParentChatItem(NSString *parentGuid, NSNumber *partIndex,
                             id *outParentMessage) {
    if (outParentMessage) *outParentMessage = nil;
    if (parentGuid.length == 0) return nil;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    if (!hcClass) return nil;
    id hc = [hcClass performSelector:@selector(sharedInstance)];
    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (!hc || ![hc respondsToSelector:loadSel]) return nil;

    __block id parent = nil;
    __block BOOL done = NO;
    NSMethodSignature *sig = [hc methodSignatureForSelector:loadSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:loadSel];
    [inv setTarget:hc];
    NSString *guid = parentGuid;
    [inv setArgument:&guid atIndex:2];
    void (^completion)(id) = ^(id m) { parent = m; done = YES; };
    [inv setArgument:&completion atIndex:3];
    [inv retainArguments];
    [inv invoke];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!parent) return nil;
    if (outParentMessage) *outParentMessage = parent;
    id parentItem = safelyReadObjectSelector(parent, @selector(_imMessageItem));
    id items = safelyReadObjectSelector(parentItem, @selector(_newChatItems));
    if (partIndex) return chatItemWithPartIndex(items, partIndex.integerValue);
    return normalizeFoundMessageItem(parent);
}

static id loadParentFirstChatItem(NSString *parentGuid, id *outParentMessage) {
    return loadParentChatItem(parentGuid, nil, outParentMessage);
}

/// Dispatch a built IMMessage into the chat after installing the same
/// thread context Messages.app keeps for inline replies. The private
/// `_sendMessage:adjustingSender:shouldQueue:` path we tried earlier may
/// silently drop items in some macOS 26 states, so use the chat registry
/// dispatch when available and fall back to `-[IMChat sendMessage:]`.
static void prepareThreadContextForSend(IMChat *chat,
                                        NSString *threadIdentifier,
                                        id threadOriginator) {
    if (!chat) return;
    if ([chat respondsToSelector:@selector(inlineReplyController)]) {
        id controller = [chat performSelector:@selector(inlineReplyController)];
        if ([controller respondsToSelector:@selector(setThreadIdentifier:)]) {
            [controller performSelector:@selector(setThreadIdentifier:)
                             withObject:(threadIdentifier.length ? threadIdentifier : nil)];
        }
        if ([controller respondsToSelector:@selector(setThreadOriginator:)]) {
            [controller performSelector:@selector(setThreadOriginator:)
                             withObject:threadOriginator];
        }
    }

    NSString *chatGUID = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : nil;
    if (!chatGUID.length) return;

    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    if (!registry) {
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass && [registryClass respondsToSelector:@selector(sharedInstance)]) {
            registry = [registryClass performSelector:@selector(sharedInstance)];
        }
    }
    if (!registry
        || ![registry respondsToSelector:@selector(chatGUIDToCurrentThreadMap)]) {
        return;
    }

    id map = [registry performSelector:@selector(chatGUIDToCurrentThreadMap)];
    if (![map isKindOfClass:[NSMutableDictionary class]]) return;
    if (threadIdentifier.length) {
        [(NSMutableDictionary *)map setObject:threadIdentifier forKey:chatGUID];
    } else {
        [(NSMutableDictionary *)map removeObjectForKey:chatGUID];
    }
}

static void clearThreadContextForChat(IMChat *chat, NSString *expectedThreadIdentifier) {
    if (!chat) return;
    if ([chat respondsToSelector:@selector(inlineReplyController)]) {
        id controller = [chat performSelector:@selector(inlineReplyController)];
        BOOL shouldClearController = YES;
        if (expectedThreadIdentifier.length
            && [controller respondsToSelector:@selector(threadIdentifier)]) {
            NSString *current =
                [controller performSelector:@selector(threadIdentifier)];
            shouldClearController =
                !current.length || [current isEqualToString:expectedThreadIdentifier];
        }
        if (shouldClearController) {
            if ([controller respondsToSelector:@selector(setThreadIdentifier:)]) {
                [controller performSelector:@selector(setThreadIdentifier:)
                                 withObject:nil];
            }
            if ([controller respondsToSelector:@selector(setThreadOriginator:)]) {
                [controller performSelector:@selector(setThreadOriginator:)
                                 withObject:nil];
            }
        }
    }

    NSString *chatGUID = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : nil;
    if (!chatGUID.length) return;

    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    if (!registry) {
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass && [registryClass respondsToSelector:@selector(sharedInstance)]) {
            registry = [registryClass performSelector:@selector(sharedInstance)];
        }
    }
    if (!registry
        || ![registry respondsToSelector:@selector(chatGUIDToCurrentThreadMap)]) {
        return;
    }

    id map = [registry performSelector:@selector(chatGUIDToCurrentThreadMap)];
    if (![map isKindOfClass:[NSMutableDictionary class]]) return;
    NSString *current = [(NSMutableDictionary *)map objectForKey:chatGUID];
    if (!expectedThreadIdentifier.length
        || !current.length
        || [current isEqualToString:expectedThreadIdentifier]) {
        [(NSMutableDictionary *)map removeObjectForKey:chatGUID];
    }
}

static void scheduleThreadContextClear(IMChat *chat, NSString *threadIdentifier) {
    if (!chat) return;
    NSString *expected = threadIdentifier ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        clearThreadContextForChat(chat, expected);
    });
}

static void dispatchIMMessageInChat(IMChat *chat,
                                    id message,
                                    NSString *threadIdentifier,
                                    id threadOriginator) {
    if (!threadIdentifier.length) {
        clearThreadContextForChat(chat, nil);
        clearReplyMetadataOnMessage(message);
        [chat performSelector:@selector(sendMessage:) withObject:message];
        return;
    }

    prepareThreadContextForSend(chat, threadIdentifier, threadOriginator);
    id registry = nil;
    if ([chat respondsToSelector:@selector(chatRegistry)]) {
        registry = [chat performSelector:@selector(chatRegistry)];
    }
    SEL registrySendSel = NSSelectorFromString(@"_chat:sendMessage:");
    if (registry && [registry respondsToSelector:registrySendSel]) {
        NSMethodSignature *sig = [registry methodSignatureForSelector:registrySendSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:registrySendSel];
        [inv setTarget:registry];
        __unsafe_unretained id chatArg = chat;
        __unsafe_unretained id messageArg = message;
        [inv setArgument:&chatArg atIndex:2];
        [inv setArgument:&messageArg atIndex:3];
        [inv invoke];
        scheduleThreadContextClear(chat, threadIdentifier);
        return;
    }
    [chat performSelector:@selector(sendMessage:) withObject:message];
    scheduleThreadContextClear(chat, threadIdentifier);
}

static unsigned long long flagsForMessagePayload(NSAttributedString *subject,
                                                 NSArray *fileTransferGuids,
                                                 BOOL isAudioMessage);

static NSString *pollsBalloonBundleIdentifier(void) {
    return @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls";
}

static BOOL pollPayloadMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:);
    return messageClass && [messageClass instancesRespondToSelector:sel];
}

static BOOL pollVoteMessageInitializerAvailable(void) {
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
    return messageClass && [messageClass instancesRespondToSelector:sel];
}

static NSString *trimmedPollString(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *activeIMessageSenderHandle(void) {
    Class accClass = NSClassFromString(@"IMAccountController");
    id ctrl = accClass ? [accClass performSelector:@selector(sharedInstance)] : nil;
    id account = nil;
    if (ctrl && [ctrl respondsToSelector:@selector(activeIMessageAccount)]) {
        account = [ctrl performSelector:@selector(activeIMessageAccount)];
    }
    if (!account) return nil;

    id login = nil;
    if ([account respondsToSelector:@selector(loginIMHandle)]) {
        login = [account performSelector:@selector(loginIMHandle)];
    }
    if (login && [login respondsToSelector:@selector(ID)]) {
        NSString *loginID = [login performSelector:@selector(ID)];
        if (loginID.length) return loginID;
    }

    if ([account respondsToSelector:@selector(vettedAliases)]) {
        NSArray *aliases = [account performSelector:@selector(vettedAliases)];
        for (id alias in aliases) {
            NSString *candidate = trimmedPollString(alias);
            if (candidate.length) return candidate;
        }
    }
    return nil;
}

static NSString *pollParticipantHandle(NSString *handle) {
    NSString *trimmed = trimmedPollString(handle);
    if (!trimmed.length) return nil;
    if ([trimmed hasPrefix:@"e:"] || [trimmed hasPrefix:@"p:"]) {
        NSString *stripped = [trimmed substringFromIndex:2];
        return stripped.length ? stripped : trimmed;
    }
    return trimmed;
}

static NSArray<NSString *> *normalizedPollOptions(NSArray *rawOptions) {
    NSMutableArray<NSString *> *options = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id raw in rawOptions) {
        NSString *text = trimmedPollString(raw);
        if (!text.length) continue;
        if ([seen containsObject:text]) continue;
        [options addObject:text];
        [seen addObject:text];
    }
    return options;
}

static NSData *pollPreviewImageData(void) {
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:162
                                                pixelsHigh:162
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:0
                                              bitsPerPixel:0];
    if (!rep) return nil;

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!context) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    [[NSColor colorWithCalibratedRed:0.96 green:0.96 blue:0.98 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, 162, 162));

    [[NSColor colorWithCalibratedRed:0.16 green:0.40 blue:0.86 alpha:1.0] setFill];
    NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(25, 25, 112, 112)
                                                          xRadius:24
                                                          yRadius:24];
    [badge fill];

    [[NSColor whiteColor] setFill];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat y = 103 - (i * 28);
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(48, y, 10, 10)] fill];
        NSBezierPath *line = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(68, y + 1, 46, 8)
                                                             xRadius:4
                                                             yRadius:4];
        [line fill];
    }

    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                             properties:@{NSImageCompressionFactor: @0.82}];
}

static NSData *archivePollLiveLayoutInfo(NSError **outError) {
    NSDictionary *layoutInfo = @{
        @"layoutClass": @"MSMessageLiveLayout",
        @"userInfo": @{}
    };
    if (@available(macOS 10.13, *)) {
        return [NSKeyedArchiver archivedDataWithRootObject:layoutInfo
                                     requiringSecureCoding:NO
                                                     error:outError];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSKeyedArchiver archivedDataWithRootObject:layoutInfo];
    #pragma clang diagnostic pop
}

static NSData *archivePollRequiredCapabilities(NSError **outError) {
    NSArray *capabilities = @[@"supports-polls"];
    if (@available(macOS 10.13, *)) {
        return [NSKeyedArchiver archivedDataWithRootObject:capabilities
                                     requiringSecureCoding:NO
                                                     error:outError];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSKeyedArchiver archivedDataWithRootObject:capabilities];
    #pragma clang diagnostic pop
}

static NSData *archivePollPayloadEnvelope(NSURL *url,
                                          NSUUID *sessionIdentifier,
                                          NSError **outError) {
    NSData *previewImage = pollPreviewImageData();
    if (!previewImage.length) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"imsg.poll"
                                           code:1
                                       userInfo:@{
                NSLocalizedDescriptionKey: @"Could not render poll preview image"
            }];
        }
        return nil;
    }

    NSError *layoutError = nil;
    NSData *liveLayoutInfo = archivePollLiveLayoutInfo(&layoutError);
    if (!liveLayoutInfo.length) {
        if (outError) *outError = layoutError;
        return nil;
    }

    NSError *capabilitiesError = nil;
    NSData *requiredCapabilities = archivePollRequiredCapabilities(&capabilitiesError);
    if (!requiredCapabilities.length) {
        if (outError) *outError = capabilitiesError;
        return nil;
    }

    NSString *previewText = @"Sent a poll";
    NSDictionary *userInfo = @{
        @"caption": previewText,
        @"tertiary-subcaption": @"",
        @"image-subtitle": @"",
        @"subcaption": @"",
        @"image-title": @"",
        @"secondary-subcaption": @""
    };
    NSDictionary *envelope = @{
        @"userInfo": userInfo,
        @"ldtext": previewText,
        @"URL": url,
        @"layoutClass": @"MSMessageTemplateLayout",
        @"ai": previewImage,
        @"sessionIdentifier": sessionIdentifier,
        @"liveLayoutInfo": liveLayoutInfo,
        @"requiredCapabilities": requiredCapabilities,
        @"sendAsText": @YES,
        @"an": @"Polls"
    };
    if (@available(macOS 10.13, *)) {
        return [NSKeyedArchiver archivedDataWithRootObject:envelope
                                     requiringSecureCoding:NO
                                                     error:outError];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSKeyedArchiver archivedDataWithRootObject:envelope];
    #pragma clang diagnostic pop
}

/// Native vote rows carry only the Polls URL and session identity. Reusing the
/// creation envelope suppresses participant markers and native notifications.
static NSData *archivePollMutationEnvelope(NSURL *url,
                                           NSUUID *sessionIdentifier,
                                           NSError **outError) {
    NSDictionary *envelope = @{
        @"URL": url,
        @"an": @"Polls",
        @"sessionIdentifier": sessionIdentifier
    };
    if (@available(macOS 10.13, *)) {
        return [NSKeyedArchiver archivedDataWithRootObject:envelope
                                     requiringSecureCoding:NO
                                                     error:outError];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSKeyedArchiver archivedDataWithRootObject:envelope];
    #pragma clang diagnostic pop
}

static NSData *buildPollCreationPayloadData(NSString *question,
                                            NSArray<NSString *> *options,
                                            NSString *creatorHandle,
                                            NSString **outSessionIdentifier,
                                            NSArray<NSString *> **outOptionIdentifiers,
                                            NSString **outError) {
    NSMutableArray<NSDictionary *> *pollOptions = [NSMutableArray array];
    NSMutableArray<NSString *> *optionIdentifiers = [NSMutableArray array];
    for (NSString *optionText in options) {
        NSString *identifier = [[NSUUID UUID] UUIDString];
        [optionIdentifiers addObject:identifier];
        NSMutableDictionary *option = [NSMutableDictionary dictionaryWithDictionary:@{
            @"canBeEdited": @NO,
            @"attributedText": optionText,
            @"text": optionText,
            @"optionIdentifier": identifier
        }];
        if (creatorHandle.length) {
            option[@"creatorHandle"] = creatorHandle;
        }
        [pollOptions addObject:option];
    }

    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:@{
        @"title": question ?: @"",
        @"orderedPollOptions": pollOptions
    }];
    if (creatorHandle.length) {
        item[@"creatorHandle"] = creatorHandle;
    }
    NSDictionary *root = @{@"item": item, @"version": @1};

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!jsonData) {
        if (outError) *outError = jsonError.localizedDescription ?: @"Could not encode poll payload";
        return nil;
    }
    if (jsonData.length > 4096) {
        if (outError) *outError = @"Poll definition payload exceeds 4096 bytes";
        return nil;
    }

    NSString *encoded = [jsonData base64EncodedStringWithOptions:0];
    NSString *urlString = [NSString stringWithFormat:@"data:,%@?src=p&c=%lu",
                                                     encoded,
                                                     (unsigned long)options.count];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = @"Could not create poll URL";
        return nil;
    }

    NSUUID *sessionIdentifier = [NSUUID UUID];
    NSError *archiveError = nil;
    NSData *payload = archivePollPayloadEnvelope(url, sessionIdentifier, &archiveError);
    if (!payload) {
        if (outError) *outError = archiveError.localizedDescription ?: @"Could not archive poll payload";
        return nil;
    }

    if (outSessionIdentifier) {
        *outSessionIdentifier = sessionIdentifier.UUIDString;
    }
    if (outOptionIdentifiers) {
        *outOptionIdentifiers = optionIdentifiers;
    }
    return payload;
}

static unsigned long long flagsForMessagePayload(NSAttributedString *subject,
                                                 NSArray *fileTransferGuids,
                                                 BOOL isAudioMessage);

static id buildBalloonIMMessage(NSString *balloonID,
                                NSAttributedString *body,
                                NSData *payloadData,
                                NSDictionary *summaryInfo,
                                NSArray *fileTransferGuids,
                                NSString *threadIdentifier,
                                NSString *replyToGUID,
                                NSString *threadOriginatorGUID,
                                NSString *threadOriginatorPart,
                                id parentItem) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;
    if (!balloonID.length) return nil;

    if (replyToGUID.length) {
        Class itemClass = NSClassFromString(@"IMMessageItem");
        SEL itemInitSel = @selector(initWithSender:time:body:attributes:fileTransferGUIDs:flags:error:guid:threadIdentifier:);
        SEL wrapSel = @selector(messageFromIMMessageItem:sender:subject:);
        if (!itemClass
            || ![itemClass instancesRespondToSelector:itemInitSel]
            || ![messageClass respondsToSelector:wrapSel]) {
            return nil;
        }

        id item = [itemClass alloc];
        if (!item) return nil;

        NSDate *now = [NSDate date];
        NSArray *transferGuids = fileTransferGuids ?: @[];
        unsigned long long flags = flagsForMessagePayload(nil, transferGuids, NO);
        NSError *err = nil;
        NSString *guid = [[NSUUID UUID] UUIDString];
        id sender = nil;
        NSDictionary *attributes = nil;
        NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

        NSMethodSignature *isig = [itemClass instanceMethodSignatureForSelector:itemInitSel];
        NSInvocation *iinv = [NSInvocation invocationWithMethodSignature:isig];
        [iinv setSelector:itemInitSel];
        [iinv setTarget:item];
        [iinv setArgument:&sender atIndex:2];
        [iinv setArgument:&now atIndex:3];
        [iinv setArgument:&body atIndex:4];
        [iinv setArgument:&attributes atIndex:5];
        [iinv setArgument:&transferGuids atIndex:6];
        [iinv setArgument:&flags atIndex:7];
        [iinv setArgument:&err atIndex:8];
        [iinv setArgument:&guid atIndex:9];
        [iinv setArgument:&messageThreadIdentifier atIndex:10];
        [iinv retainArguments];
        item = invokeReturningObject(iinv);
        if (!item) return nil;

        if ([item respondsToSelector:@selector(_regenerateBodyData)]) {
            [item performSelector:@selector(_regenerateBodyData)];
        }
        ensureItemBodyData(item, body);

        if (![item respondsToSelector:@selector(setBalloonBundleID:)]
            || ![item respondsToSelector:@selector(setPayloadData:)]
            || ![item respondsToSelector:@selector(setReplyToGUID:)]) {
            return nil;
        }
        if (summaryInfo
            && ![item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
            return nil;
        }
        if (messageThreadIdentifier
            && ![item respondsToSelector:@selector(setThreadIdentifier:)]) {
            return nil;
        }
        if (parentItem
            && ![item respondsToSelector:@selector(setThreadOriginator:)]) {
            return nil;
        }
        [item performSelector:@selector(setBalloonBundleID:) withObject:balloonID];
        [item performSelector:@selector(setPayloadData:) withObject:payloadData];
        [item performSelector:@selector(setReplyToGUID:) withObject:replyToGUID];
        if (summaryInfo
            && [item respondsToSelector:@selector(setMessageSummaryInfo:)]) {
            [item performSelector:@selector(setMessageSummaryInfo:)
                       withObject:summaryInfo];
        }
        if (messageThreadIdentifier
            && [item respondsToSelector:@selector(setThreadIdentifier:)]) {
            [item performSelector:@selector(setThreadIdentifier:)
                       withObject:messageThreadIdentifier];
        }
        if (parentItem
            && [item respondsToSelector:@selector(setThreadOriginator:)]) {
            [item performSelector:@selector(setThreadOriginator:)
                       withObject:parentItem];
        }
        if (threadOriginatorGUID.length) {
            SEL sel = NSSelectorFromString(@"setThreadOriginatorGUID:");
            if ([item respondsToSelector:sel]) {
                [item performSelector:sel withObject:threadOriginatorGUID];
            }
        }
        if (threadOriginatorPart.length) {
            SEL sel = NSSelectorFromString(@"setThreadOriginatorPart:");
            if ([item respondsToSelector:sel]) {
                [item performSelector:sel withObject:threadOriginatorPart];
            }
        }

        NSMethodSignature *wsig = [messageClass methodSignatureForSelector:wrapSel];
        NSInvocation *winv = [NSInvocation invocationWithMethodSignature:wsig];
        [winv setSelector:wrapSel];
        [winv setTarget:messageClass];
        id nilSender = nil;
        id nilSubject = nil;
        [winv setArgument:&item atIndex:2];
        [winv setArgument:&nilSender atIndex:3];
        [winv setArgument:&nilSubject atIndex:4];
        [winv retainArguments];
        return invokeReturningObject(winv);
    }

    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:messageSummaryInfo:);
    if (![messageClass instancesRespondToSelector:sel]) return nil;

    id msg = [[messageClass alloc] init];
    NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:msg];

    id nilObj = nil;
    NSDate *now = [NSDate date];
    NSArray *transferGuids = fileTransferGuids ?: @[];
    unsigned long long flags = flagsForMessagePayload(nil, transferGuids, NO);
    unsigned long long scheduleType = 0;
    unsigned long long scheduleState = 0;
    NSString *messageThreadIdentifier = threadIdentifier.length ? threadIdentifier : nil;

    [inv setArgument:&nilObj atIndex:2];              // sender
    [inv setArgument:&now atIndex:3];                 // time
    [inv setArgument:&body atIndex:4];                // text
    [inv setArgument:&nilObj atIndex:5];              // messageSubject
    [inv setArgument:&transferGuids atIndex:6];
    [inv setArgument:&flags atIndex:7];
    [inv setArgument:&nilObj atIndex:8];              // error
    [inv setArgument:&nilObj atIndex:9];              // guid
    [inv setArgument:&nilObj atIndex:10];             // subject string
    [inv setArgument:&balloonID atIndex:11];
    [inv setArgument:&payloadData atIndex:12];
    [inv setArgument:&nilObj atIndex:13];             // expressiveSendStyleID
    [inv setArgument:&messageThreadIdentifier atIndex:14];
    [inv setArgument:&scheduleType atIndex:15];
    [inv setArgument:&scheduleState atIndex:16];
    [inv setArgument:&summaryInfo atIndex:17];
    [inv retainArguments];
    id result = invokeReturningObject(inv);
    if (!messageThreadIdentifier.length) {
        clearReplyMetadataOnMessage(result);
    }
    return result;
}

static id buildPollIMMessage(NSAttributedString *body,
                             NSData *payloadData,
                             NSDictionary *summaryInfo,
                             NSString *threadIdentifier,
                             NSString *replyToGUID,
                             NSString *threadOriginatorGUID,
                             NSString *threadOriginatorPart,
                             id parentItem) {
    return buildBalloonIMMessage(pollsBalloonBundleIdentifier(),
                                 body,
                                 payloadData,
                                 summaryInfo,
                                 @[],
                                 threadIdentifier,
                                 replyToGUID,
                                 threadOriginatorGUID,
                                 threadOriginatorPart,
                                 parentItem);
}

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

static NSString *threadOriginatorPartForChatItem(id parentItem) {
    if (!parentItem
        || ![parentItem respondsToSelector:@selector(messagePartRange)]) {
        return nil;
    }
    NSRange range = [(IMMessagePartChatItem *)parentItem messagePartRange];
    if (range.length == 0) return nil;

    NSInteger partIndex = 0;
    SEL indexSel = @selector(index);
    if ([parentItem respondsToSelector:indexSel]) {
        NSMethodSignature *sig = [parentItem methodSignatureForSelector:indexSel];
        if (sig && strcmp(sig.methodReturnType, @encode(NSInteger)) == 0) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:indexSel];
            [inv setTarget:parentItem];
            [inv invoke];
            [inv getReturnValue:&partIndex];
        }
    }

    return [NSString stringWithFormat:@"%ld:%lu:%lu",
                                      (long)partIndex,
                                      (unsigned long)range.location,
                                      (unsigned long)range.length];
}

static void applyThreadOriginatorGUIDHints(id object,
                                           NSString *threadOriginatorGUID,
                                           NSString *threadOriginatorPart) {
    if (!object) return;
    if (threadOriginatorGUID.length) {
        SEL sel = NSSelectorFromString(@"setThreadOriginatorGUID:");
        if ([object respondsToSelector:sel]) {
            [object performSelector:sel withObject:threadOriginatorGUID];
        }
    }
    if (threadOriginatorPart.length) {
        SEL sel = NSSelectorFromString(@"setThreadOriginatorPart:");
        if ([object respondsToSelector:sel]) {
            [object performSelector:sel withObject:threadOriginatorPart];
        }
    }
}

static unsigned long long flagsForMessagePayload(NSAttributedString *subject,
                                                 NSArray *fileTransferGuids,
                                                 BOOL isAudioMessage) {
    if (isAudioMessage) {
        return 0x300005ULL;
    }
    if (subject.length) {
        return 0x10000dULL;
    }
    if (fileTransferGuids.count > 0) {
        return 0x100005ULL;
    }
    return 0x100005ULL;
}

static unsigned long long flagsForAssociatedMessagePayload(NSAttributedString *subject,
                                                           NSArray *fileTransferGuids,
                                                           BOOL isAudioMessage) {
    if (fileTransferGuids.count == 0) {
        return 0x5ULL;
    }
    return flagsForMessagePayload(subject, fileTransferGuids, isAudioMessage);
}

/// Build an IMMessage suitable for `[chat sendMessage:]`. Handles plain text,
/// optional subject, optional effect (`com.apple.MobileSMS.expressivesend.*`),
/// optional reply target (`selectedMessageGuid`), and ddScan flag.
///
/// On macOS 26 `+initIMMessageWith…` returns a message whose underlying
/// IMMessageItem has empty `bodyData`, which imagent silently drops. Try the
/// IMMessageItem-first path first; fall back to the legacy initializer for
/// older OSes that don't expose the modern item-construction selectors.
static id buildIMMessage(NSAttributedString *body,
                         NSAttributedString *subject,
                         NSString *effectId,
                         NSString *threadIdentifier,
                         id threadOriginator,
                         NSString *associatedMessageGuid,
                         long long associatedMessageType,
                         NSRange associatedMessageRange,
                         NSDictionary *summaryInfo,
                         NSArray *fileTransferGuids,
                         BOOL isAudioMessage,
                         BOOL ddScan) {
    // Reactions take a different code path entirely (macOS 26 init below) —
    // the IMMessageItem-first construction can't carry associated-message
    // fields atomically, and post-init setters don't survive the wrap.
    //
    // Attachments also bypass IMMessageItem-first: BB's `initWithSender:…:
    // expressiveSendStyleID:` (further down) handles fileTransferGUIDs
    // natively, and going through IMMessageItem-first appears to leave the
    // attachment payload unfinalized even with the right flags.
    BOOL isReaction = associatedMessageGuid.length && associatedMessageType > 0;
    BOOL hasAttachment = fileTransferGuids.count > 0;
    if (!isReaction && !hasAttachment) {
        id viaItem = constructIMMessageViaItem(body, subject, effectId,
                                                threadIdentifier,
                                                threadOriginator,
                                                associatedMessageGuid,
                                                associatedMessageType,
                                                associatedMessageRange,
                                                summaryInfo,
                                                fileTransferGuids,
                                                isAudioMessage);
        if (viaItem) return viaItem;
    }
    // Legacy fallback for older macOS that doesn't expose the
    // IMMessageItem 9-arg initializer or +messageFromIMMessageItem:.
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;

    // Reaction / reply path: associatedMessageGuid + associatedMessageType.
    if (associatedMessageGuid.length && associatedMessageType > 0) {
        // macOS 26 path (BlueBubblesHelper-verified, 13 args, no
        // balloonBundleID/payloadData/expressiveSendStyleID). BB allocates
        // and inits in two steps: `[[IMMessage alloc] init]` then call this
        // longer initializer on the result.
        SEL macos26Sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
        if ([messageClass instancesRespondToSelector:macos26Sel]) {
            unsigned long long flags = flagsForAssociatedMessagePayload(subject,
                                                                        fileTransferGuids,
                                                                        isAudioMessage);
            id msg = [[messageClass alloc] init];
            NSMethodSignature *sig =
                [messageClass instanceMethodSignatureForSelector:macos26Sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:macos26Sel];
            [inv setTarget:msg];
            id nilObj = nil;
            NSDate *now = [NSDate date];
            [inv setArgument:&nilObj atIndex:2];           // sender
            [inv setArgument:&now atIndex:3];              // time
            [inv setArgument:&body atIndex:4];             // text
            [inv setArgument:&subject atIndex:5];          // messageSubject
            [inv setArgument:&fileTransferGuids atIndex:6];
            [inv setArgument:&flags atIndex:7];
            [inv setArgument:&nilObj atIndex:8];           // error
            [inv setArgument:&nilObj atIndex:9];           // guid
            [inv setArgument:&nilObj atIndex:10];          // subject (string)
            [inv setArgument:&associatedMessageGuid atIndex:11];
            [inv setArgument:&associatedMessageType atIndex:12];
            [inv setArgument:&associatedMessageRange atIndex:13];
            [inv setArgument:&summaryInfo atIndex:14];
            [inv retainArguments];
            id result = invokeReturningObject(inv);
            debugLog(@"buildIMMessage: reaction via macos26Sel result=%@",
                     result ? NSStringFromClass([result class]) : @"(nil)");
            if (result) {
                if (threadIdentifier
                    && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                    [result performSelector:@selector(setThreadIdentifier:)
                                 withObject:threadIdentifier];
                }
                return result;
            }
        }

        // Legacy 17-arg form for older macOS.
        SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
        BOOL responds = [messageClass instancesRespondToSelector:sel];
        debugLog(@"buildIMMessage: reaction path; long-init responds=%d type=%lld guid=%@",
                 responds, associatedMessageType, associatedMessageGuid);
        id msg = [messageClass alloc];
        if ([msg respondsToSelector:sel]) {
            unsigned long long flags = flagsForAssociatedMessagePayload(subject,
                                                                        fileTransferGuids,
                                                                        isAudioMessage);
            NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:msg];
            id nilObj = nil;
            NSDate *now = [NSDate date];
            [inv setArgument:&nilObj atIndex:2];        // sender
            [inv setArgument:&now atIndex:3];           // time
            [inv setArgument:&body atIndex:4];          // text
            [inv setArgument:&subject atIndex:5];       // messageSubject
            [inv setArgument:&fileTransferGuids atIndex:6];
            [inv setArgument:&flags atIndex:7];
            [inv setArgument:&nilObj atIndex:8];        // error
            [inv setArgument:&nilObj atIndex:9];        // guid
            [inv setArgument:&nilObj atIndex:10];       // subject (string form)
            [inv setArgument:&nilObj atIndex:11];       // balloonBundleID
            [inv setArgument:&nilObj atIndex:12];       // payloadData
            [inv setArgument:&effectId atIndex:13];     // expressiveSendStyleID
            [inv setArgument:&associatedMessageGuid atIndex:14];
            [inv setArgument:&associatedMessageType atIndex:15];
            [inv setArgument:&associatedMessageRange atIndex:16];
            [inv setArgument:&summaryInfo atIndex:17];
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            if (threadIdentifier
                && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                [result performSelector:@selector(setThreadIdentifier:)
                             withObject:threadIdentifier];
            }
            return result;
        }
    }

    if (isReaction) {
        // Never degrade associated-message semantics into a normal send.
        return nil;
    }

    // Normal send / reply path. Try the BB-verified macOS 26 selector
    // (`initWithSender:…:expressiveSendStyleID:`, 12 args, no `IMMessage`
    // prefix) first; fall back to the legacy `initIMMessageWithSender:` for
    // older releases.
    SEL bbSendSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:);
    if ([messageClass instancesRespondToSelector:bbSendSel]) {
        unsigned long long flags = flagsForMessagePayload(subject, fileTransferGuids,
                                                          isAudioMessage);
        id m = [[messageClass alloc] init];
        NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:bbSendSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:bbSendSel];
        [inv setTarget:m];
        id nilObj = nil;
        NSDate *now = [NSDate date];
        [inv setArgument:&nilObj atIndex:2];           // sender
        [inv setArgument:&now atIndex:3];              // time
        [inv setArgument:&body atIndex:4];             // text
        [inv setArgument:&subject atIndex:5];          // messageSubject
        [inv setArgument:&fileTransferGuids atIndex:6];
        [inv setArgument:&flags atIndex:7];
        [inv setArgument:&nilObj atIndex:8];           // error
        [inv setArgument:&nilObj atIndex:9];           // guid
        [inv setArgument:&nilObj atIndex:10];          // subject string
        [inv setArgument:&nilObj atIndex:11];          // balloonBundleID
        [inv setArgument:&nilObj atIndex:12];          // payloadData
        [inv setArgument:&effectId atIndex:13];        // expressiveSendStyleID
        [inv retainArguments];
        id result = invokeReturningObject(inv);
        if (result) {
            if (threadIdentifier
                && [result respondsToSelector:@selector(setThreadIdentifier:)]) {
                [result performSelector:@selector(setThreadIdentifier:)
                             withObject:threadIdentifier];
            }
            if (!threadIdentifier.length) {
                clearReplyMetadataOnMessage(result);
            }
            return result;
        }
    }

    SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:);
    id msg = [messageClass alloc];
    if ([msg respondsToSelector:sel]) {
        unsigned long long flags = flagsForMessagePayload(subject, fileTransferGuids,
                                                          isAudioMessage);
        NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:msg];
        id nilObj = nil;
        NSDate *now = [NSDate date];
        [inv setArgument:&nilObj atIndex:2];           // sender
        [inv setArgument:&now atIndex:3];              // time
        [inv setArgument:&body atIndex:4];             // text
        [inv setArgument:&subject atIndex:5];          // messageSubject
        [inv setArgument:&fileTransferGuids atIndex:6];
        [inv setArgument:&flags atIndex:7];
        [inv setArgument:&nilObj atIndex:8];           // error
        [inv setArgument:&nilObj atIndex:9];           // guid
        [inv setArgument:&nilObj atIndex:10];          // subject string
        [inv setArgument:&nilObj atIndex:11];          // balloonBundleID
        [inv setArgument:&nilObj atIndex:12];          // payloadData
        [inv setArgument:&effectId atIndex:13];        // expressiveSendStyleID
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        if (!threadIdentifier.length) {
            clearReplyMetadataOnMessage(result);
        }
        return result;
    }

    // The simplest initializer cannot carry transfer GUIDs. An attachment
    // must fail closed instead of reporting a successful text-only send.
    if (hasAttachment) return nil;

    // Last resort: simplest 2-arg initializer if the long form isn't available.
    SEL simple = @selector(initWithText:flags:);
    if ([msg respondsToSelector:simple]) {
        unsigned long long flags = 0x100005ULL;
        NSMethodSignature *sig2 = [messageClass instanceMethodSignatureForSelector:simple];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig2];
        [inv setSelector:simple];
        [inv setTarget:msg];
        [inv setArgument:&body atIndex:2];
        [inv setArgument:&flags atIndex:3];
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        if (!threadIdentifier.length) {
            clearReplyMetadataOnMessage(result);
        }
        return result;
    }
    return nil;
}

/// Look up a chat item by message guid. Tries BlueBubblesHelper's
/// block-based `loadMessageWithGUID:completionBlock:` first — that path
/// works for messages older than what's currently loaded into the live
/// `chat.chatItems` window. Falls back to the older
/// `loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:` + sync poll
/// for OSes that don't expose the block-based load.
static id findMessageItemInObject(id object,
                                  NSString *messageGuid,
                                  NSMutableSet<NSValue *> *visited,
                                  NSUInteger depth) {
    if (!object || !messageGuid.length || depth > 8) return nil;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    SEL guidSel = @selector(guid);
    if ([object respondsToSelector:guidSel]) {
        id guid = safelyReadObjectSelector(object, guidSel);
        if ([guid isKindOfClass:[NSString class]]
            && [guid isEqualToString:messageGuid]) {
            id normalized = normalizeFoundMessageItem(object);
            if (normalized) return normalized;
        }
    }

    // Threaded replies can sit below a top-level transcript item. Walk both
    // public-ish wrappers and private backing objects, with a small depth cap
    // and identity set so cyclic IMCore graphs cannot recurse forever.
    NSArray<NSString *> *objectSelectors = @[
        @"message", @"messageItem", @"_item", @"_imMessageItem"
    ];
    for (NSString *name in objectSelectors) {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) continue;
        id child = safelyReadObjectSelector(object, sel);
        id match = findMessageItemInObject(child, messageGuid, visited, depth + 1);
        if (match) return match;
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_newChatItems", @"chatItems", @"aggregateAttachmentParts"
    ];
    for (NSString *name in collectionSelectors) {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) continue;
        id children = safelyReadObjectSelector(object, sel);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in (NSArray *)children) {
            id match = findMessageItemInObject(child, messageGuid, visited, depth + 1);
            if (match) return match;
        }
    }
    return nil;
}

static id findMessageItem(IMChat *chat, NSString *messageGuid) {
    if (!chat || !messageGuid.length) {
        return nil;
    }

    // BB-verified macOS 11+ path: block-based load via IMChatHistoryController
    // (returns an IMMessage). Callers want the chat item, so navigate
    // IMMessage → IMMessageItem → first IMMessagePartChatItem via the
    // same accessor walk loadParentFirstChatItem performs.
    id loadedMessage = nil;
    id loadedChatItem = loadParentFirstChatItem(messageGuid, &loadedMessage);
    if (!loadedChatItem && loadedMessage) {
        Class contextClass = NSClassFromString(@"IMMutableChatContext");
        SEL contextSel = NSSelectorFromString(@"chatContextForPinnedChat:");
        id chatContext = safelyReadObjectSelectorWithObject(contextClass, contextSel, chat);
        loadedChatItem = normalizeFoundMessageItemWithChatContext(
            loadedMessage, chatContext);
    }
    if (loadedChatItem) return loadedChatItem;

    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    id hc = hcClass ? [hcClass performSelector:@selector(sharedInstance)] : nil;
    if (hc && [hc respondsToSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)]) {
        NSMethodSignature *sig = [hc methodSignatureForSelector:
            @selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        [inv setTarget:hc];
        [inv setArgument:&chat atIndex:2];
        NSDate *now = [NSDate date];
        [inv setArgument:&now atIndex:3];
        NSUInteger limit = 100;
        [inv setArgument:&limit atIndex:4];
        BOOL load = YES;
        [inv setArgument:&load atIndex:5];
        [inv invoke];
    }

    // Poll chat.chatItems for the guid for up to 2s. Spinning the current
    // run loop gives IMCore a chance to finish loading requested chat items.
    for (NSInteger attempts = 0; attempts < 20; attempts++) {
        NSArray *items = nil;
        if ([chat respondsToSelector:@selector(chatItems)]) {
            items = [chat performSelector:@selector(chatItems)];
        }
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        for (id item in items) {
            id match = findMessageItemInObject(item, messageGuid, visited, 0);
            if (match) return match;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return nil;
}

static id findMessagePartInObject(id object, NSInteger partIndex) {
    if (!object) return nil;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)object) {
            id match = findMessagePartInObject(child, partIndex);
            if (match) return match;
        }
        return nil;
    }

    id aggregate = safelyReadObjectSelector(
        object, @selector(aggregateAttachmentParts));
    id aggregateMatch = findMessagePartInObject(aggregate, partIndex);
    if (aggregateMatch) return aggregateMatch;

    if ([object respondsToSelector:@selector(index)]) {
        @try {
            if ([(IMMessagePartChatItem *)object index] == partIndex) return object;
        } @catch (__unused NSException *exception) {
        }
        return nil;
    }
    return partIndex == 0 ? object : nil;
}

static id findMessagePart(IMChat *chat, NSString *messageGuid, NSInteger partIndex) {
    id item = findMessageItem(chat, messageGuid);
    if (!item) return nil;

    id messageItem = safelyReadObjectSelector(item, @selector(messageItem));
    if (!messageItem) messageItem = item;

    Class contextClass = NSClassFromString(@"IMMutableChatContext");
    SEL contextSel = NSSelectorFromString(@"chatContextForPinnedChat:");
    id chatContext = safelyReadObjectSelectorWithObject(
        contextClass, contextSel, chat);

    id parts = safelyReadObjectSelector(messageItem, @selector(_newChatItems));
    BOOL partsMissing = !parts
        || ([parts isKindOfClass:[NSArray class]] && ((NSArray *)parts).count == 0);
    if (partsMissing && chatContext) {
        SEL contextItemsSel = NSSelectorFromString(@"_newChatItemsWithChatContext:");
        parts = safelyReadObjectSelectorWithObject(
            messageItem, contextItemsSel, chatContext);
        partsMissing = !parts
            || ([parts isKindOfClass:[NSArray class]] && ((NSArray *)parts).count == 0);
        if (partsMissing) {
            Class partClass = NSClassFromString(@"IMMessagePartChatItem");
            SEL partsSel = NSSelectorFromString(
                @"_newMessagePartsForMessageItem:chatContext:");
            parts = safelyReadObjectSelectorWithTwoObjects(
                partClass, partsSel, messageItem, chatContext);
        }
    }

    return findMessagePartInObject(parts ?: item, partIndex);
}

/// Best-effort messageGuid extractor for transactional sends. Returns the
/// guid of `chat.lastSentMessage` after a brief grace period for the message
/// to register, or nil if unavailable.
static NSString *lastSentMessageGuid(IMChat *chat) {
    if (!chat || ![chat respondsToSelector:@selector(lastSentMessage)]) return nil;
    id msg = [chat performSelector:@selector(lastSentMessage)];
    if (msg && [msg respondsToSelector:@selector(guid)]) {
        return [msg performSelector:@selector(guid)];
    }
    return nil;
}

#pragma mark - v2 Response Helpers

/// Build a v2-shaped success envelope: { v:2, id, success:true, data:{...} }
static NSDictionary* successResponseV2(NSString *uuid, NSDictionary *data) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @YES,
        @"data": data ?: @{},
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

/// Build a v2-shaped error envelope.
static NSDictionary* errorResponseV2(NSString *uuid, NSString *error) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Inbound Events (v2)

/// Append a single JSON object as a line to `.imsg-events.jsonl`. Rotates the
/// file once it crosses kEventsRotateBytes by renaming to `.1` (overwriting).
/// Safe to call from any thread (guarded by an unfair lock).
__attribute__((unused))
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

#pragma mark - Send Handlers (v2)

static NSString *richLinkActualUserHomeDirectory(void) {
    struct passwd *entry = getpwuid(getuid());
    if (!entry || !entry->pw_dir) return nil;
    return [NSString stringWithUTF8String:entry->pw_dir];
}

static NSString *trustedRichLinkStagingRoot(void) {
    return [[richLinkActualUserHomeDirectory()
        stringByAppendingPathComponent:@"Library/Messages/Attachments/imsg"]
        stringByStandardizingPath];
}

static BOOL richLinkPathIsTrusted(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) return NO;
    NSString *root = trustedRichLinkStagingRoot();
    NSString *candidate = path.stringByStandardizingPath;
    return root.length && [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static int openRichLinkDirectorySecurely(NSString *directoryPath) {
    NSString *root = trustedRichLinkStagingRoot();
    NSString *candidate = directoryPath.stringByStandardizingPath;
    if (!root.length || !candidate.length) return -1;
    BOOL isRoot = [candidate isEqualToString:root];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    if (!isRoot && ![candidate hasPrefix:rootPrefix]) return -1;

    int directoryFD = open(root.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
    if (directoryFD < 0) return -1;
    struct stat rootStat = {0};
    if (fstat(directoryFD, &rootStat) != 0 || !S_ISDIR(rootStat.st_mode) ||
        rootStat.st_uid != getuid() || (rootStat.st_mode & S_IWOTH) != 0) {
        close(directoryFD);
        return -1;
    }
    if (isRoot) return directoryFD;

    NSString *relative = [candidate substringFromIndex:rootPrefix.length];
    NSArray<NSString *> *components = relative.pathComponents;
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        int nextFD = openat(directoryFD, component.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
        close(directoryFD);
        if (nextFD < 0) return -1;
        directoryFD = nextFD;
    }
    return directoryFD;
}

static NSString *richLinkSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL richLinkIntegerNumber(NSNumber *number) {
    if (![number isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
    return !CFNumberIsFloatType((__bridge CFNumberRef)number);
}

static NSData *readRichLinkPreviewData(NSString *path,
                                       unsigned long long expectedSize,
                                       NSString **outErr) {
    if (!richLinkPathIsTrusted(path)) {
        if (outErr) *outErr = @"Rich-link image path is outside the secure staging directory";
        return nil;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    int directoryFD = openRichLinkDirectorySecurely(directory);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open rich-link image directory";
        return nil;
    }
    int fd = openat(directoryFD, path.lastPathComponent.fileSystemRepresentation,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    close(directoryFD);
    if (fd < 0) {
        if (outErr) *outErr = @"Could not securely open rich-link image";
        return nil;
    }
    struct stat before = {0};
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
        before.st_size <= 0 || (unsigned long long)before.st_size != expectedSize ||
        expectedSize > 2ULL * 1024ULL * 1024ULL) {
        close(fd);
        if (outErr) *outErr = @"Rich-link image file does not match its descriptor";
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)before.st_size];
    unsigned char buffer[64 * 1024];
    while (YES) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd);
            if (outErr) *outErr = @"Could not read rich-link image";
            return nil;
        }
        if ((unsigned long long)data.length + (unsigned long long)count > expectedSize) {
            close(fd);
            if (outErr) *outErr = @"Rich-link image changed while being read";
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    struct stat after = {0};
    BOOL changed = fstat(fd, &after) != 0
        || after.st_dev != before.st_dev
        || after.st_ino != before.st_ino
        || after.st_size != before.st_size
        || after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec
        || after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec
        || after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
        || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec;
    close(fd);
    if (changed || data.length != (NSUInteger)expectedSize) {
        if (outErr) *outErr = @"Rich-link image changed while being read";
        return nil;
    }
    return data;
}

static NSString *writeRichLinkPreviewSnapshot(NSData *data,
                                              NSString *contentHash,
                                              NSString **outErr) {
    NSString *root = trustedRichLinkStagingRoot();
    int rootFD = openRichLinkDirectorySecurely(root);
    if (rootFD < 0) {
        if (outErr) *outErr = @"Could not securely open rich-link staging root";
        return nil;
    }
    if (mkdirat(rootFD, "rich-links", 0700) != 0 && errno != EEXIST) {
        close(rootFD);
        if (outErr) *outErr = @"Could not create private rich-link directory";
        return nil;
    }
    int previewsFD = openat(rootFD, "rich-links",
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    close(rootFD);
    if (previewsFD < 0) {
        if (outErr) *outErr = @"Could not open private rich-link directory";
        return nil;
    }
    NSString *directoryName = NSUUID.UUID.UUIDString;
    if (mkdirat(previewsFD, directoryName.fileSystemRepresentation, 0700) != 0) {
        close(previewsFD);
        if (outErr) *outErr = @"Could not create private rich-link snapshot directory";
        return nil;
    }
    int directoryFD = openat(previewsFD, directoryName.fileSystemRepresentation,
                             O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (directoryFD < 0) {
        unlinkat(previewsFD, directoryName.fileSystemRepresentation, AT_REMOVEDIR);
        close(previewsFD);
        if (outErr) *outErr = @"Could not open private rich-link snapshot directory";
        return nil;
    }
    NSString *filename = [contentHash stringByAppendingString:@".pluginPayloadAttachment"];
    int fd = openat(directoryFD, filename.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0;
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (!ok) {
        unlinkat(directoryFD, filename.fileSystemRepresentation, 0);
        close(directoryFD);
        unlinkat(previewsFD, directoryName.fileSystemRepresentation, AT_REMOVEDIR);
        close(previewsFD);
        if (outErr) *outErr = @"Could not write private rich-link snapshot";
        return nil;
    }
    close(directoryFD);
    close(previewsFD);
    return [[[root stringByAppendingPathComponent:@"rich-links"]
        stringByAppendingPathComponent:directoryName]
        stringByAppendingPathComponent:filename];
}

static void removeRichLinkPreviewSnapshot(NSString *path) {
    NSString *root = [[trustedRichLinkStagingRoot()
        stringByAppendingPathComponent:@"rich-links"] stringByStandardizingPath];
    NSString *candidate = path.stringByStandardizingPath;
    if (!root.length || ![candidate hasPrefix:[root stringByAppendingString:@"/"]]) return;
    NSString *directory = candidate.stringByDeletingLastPathComponent;
    int directoryFD = openRichLinkDirectorySecurely(directory);
    if (directoryFD >= 0) {
        unlinkat(directoryFD, candidate.lastPathComponent.fileSystemRepresentation, 0);
        close(directoryFD);
    }
    NSString *parent = directory.stringByDeletingLastPathComponent;
    int parentFD = openRichLinkDirectorySecurely(parent);
    if (parentFD >= 0) {
        unlinkat(parentFD, directory.lastPathComponent.fileSystemRepresentation, AT_REMOVEDIR);
        close(parentFD);
    }
}

static BOOL validateRichLinkPreviewImage(NSDictionary *image,
                                         NSURL **outFileURL,
                                         NSString **outMimeType,
                                         NSString **outErr) {
    if (!image) return YES;
    NSSet *allowedKeys = [NSSet setWithArray:@[
        @"filePath", @"mimeType", @"contentHash", @"byteCount",
        @"pixelWidth", @"pixelHeight"
    ]];
    for (id key in image) {
        if (![key isKindOfClass:[NSString class]] || ![allowedKeys containsObject:key]) {
            if (outErr) *outErr = @"Invalid rich-link image descriptor";
            return NO;
        }
    }
    NSString *filePath = [image[@"filePath"] isKindOfClass:[NSString class]]
        ? image[@"filePath"] : @"";
    NSString *mimeType = [image[@"mimeType"] isKindOfClass:[NSString class]]
        ? [image[@"mimeType"] lowercaseString] : @"";
    NSString *contentHash = [image[@"contentHash"] isKindOfClass:[NSString class]]
        ? [image[@"contentHash"] lowercaseString] : @"";
    NSNumber *byteCount = image[@"byteCount"];
    NSNumber *pixelWidth = image[@"pixelWidth"];
    NSNumber *pixelHeight = image[@"pixelHeight"];
    NSSet *allowedMIMETypes = [NSSet setWithArray:@[
        @"image/jpeg", @"image/png", @"image/webp"
    ]];
    NSInteger width = pixelWidth.integerValue;
    NSInteger height = pixelHeight.integerValue;
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    if (!filePath.length || ![filePath hasSuffix:@".pluginPayloadAttachment"] ||
        ![allowedMIMETypes containsObject:mimeType] || contentHash.length != 64 ||
        [contentHash rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
        !richLinkIntegerNumber(byteCount) || !richLinkIntegerNumber(pixelWidth) ||
        !richLinkIntegerNumber(pixelHeight) ||
        byteCount.longLongValue <= 0 || byteCount.longLongValue > 2 * 1024 * 1024 ||
        width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        width > (16 * 1024 * 1024) / height) {
        if (outErr) *outErr = @"Rich-link image metadata exceeds safe limits";
        return NO;
    }

    NSData *data = readRichLinkPreviewData(filePath.stringByStandardizingPath,
        byteCount.unsignedLongLongValue, outErr);
    if (!data) return NO;
    if (![[richLinkSHA256(data) lowercaseString] isEqualToString:contentHash]) {
        if (outErr) *outErr = @"Rich-link image hash does not match its descriptor";
        return NO;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source || CGImageSourceGetCount(source) != 1) {
        if (source) CFRelease(source);
        if (outErr) *outErr = @"Rich-link image must contain exactly one decodable frame";
        return NO;
    }
    NSString *uti = (__bridge NSString *)CGImageSourceGetType(source);
    BOOL typeMatches = ([mimeType isEqualToString:@"image/png"] && [uti isEqualToString:@"public.png"])
        || ([mimeType isEqualToString:@"image/jpeg"] && [uti isEqualToString:@"public.jpeg"])
        || ([mimeType isEqualToString:@"image/webp"] &&
            ([uti isEqualToString:@"org.webmproject.webp"] || [uti isEqualToString:@"public.webp"]));
    CFDictionaryRef rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    NSDictionary *properties = CFBridgingRelease(rawProperties);
    NSInteger actualWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger actualHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] integerValue];
    if (!typeMatches || !properties || actualWidth != width || actualHeight != height) {
        CFRelease(source);
        if (outErr) *outErr = @"Rich-link image metadata does not match its descriptor";
        return NO;
    }
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!decoded) {
        if (outErr) *outErr = @"Rich-link image could not be decoded safely";
        return NO;
    }
    CGImageRelease(decoded);
    NSString *snapshotPath = writeRichLinkPreviewSnapshot(data, contentHash, outErr);
    if (!snapshotPath.length) return NO;
    if (outFileURL) *outFileURL = [NSURL fileURLWithPath:snapshotPath];
    if (outMimeType) *outMimeType = mimeType;
    return YES;
}

/// Implementation core for `send-message`. Builds an IMMessage with optional
/// effect/subject/reply and dispatches via `[chat sendMessage:]`. ddScan on
/// macOS 13+ defers the send by 100ms.
static NSDictionary *handleSendMessage(NSInteger requestId, NSDictionary *params) {
    id chatGuidValue = params[@"chatGuid"];
    id messageValue = params[@"message"];
    id effectIdValue = params[@"effectId"];
    id subjectValue = params[@"subject"];
    id selectedMessageGuidValue = params[@"selectedMessageGuid"];
    id richLinkValue = params[@"richLinkPreview"];
    id partIndexValue = params[@"partIndex"];
    id ddScanValue = params[@"ddScan"];
    id attributedBodyValue = params[@"attributedBody"];
    id textFormattingValue = params[@"textFormatting"];
    if (![chatGuidValue isKindOfClass:[NSString class]] ||
        (messageValue && ![messageValue isKindOfClass:[NSString class]]) ||
        (effectIdValue && ![effectIdValue isKindOfClass:[NSString class]]) ||
        (subjectValue && ![subjectValue isKindOfClass:[NSString class]]) ||
        (selectedMessageGuidValue &&
         ![selectedMessageGuidValue isKindOfClass:[NSString class]]) ||
        (richLinkValue && ![richLinkValue isKindOfClass:[NSDictionary class]]) ||
        (partIndexValue && !richLinkIntegerNumber(partIndexValue)) ||
        (ddScanValue && ![ddScanValue isKindOfClass:[NSNumber class]]) ||
        (attributedBodyValue && ![attributedBodyValue isKindOfClass:[NSString class]]) ||
        (textFormattingValue && ![textFormattingValue isKindOfClass:[NSArray class]])) {
        return errorResponse(requestId, @"Invalid send-message parameter types");
    }

    NSString *chatGuid = chatGuidValue;
    NSString *message = messageValue;
    NSString *effectId = effectIdValue;
    NSString *subject = subjectValue;
    NSString *selectedMessageGuid = selectedMessageGuidValue;
    NSDictionary *richLinkPreview = richLinkValue;
    NSNumber *partIndexNum = partIndexValue;
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;
    NSNumber *ddScanNum = ddScanValue;
    BOOL ddScan = [ddScanNum boolValue];
    NSString *attributedBodyB64 = attributedBodyValue;
    NSArray *textFormatting = textFormattingValue;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!message) message = @"";
    if (richLinkPreview &&
        (effectId.length || subject.length || selectedMessageGuid.length || partIndex != 0 ||
         attributedBodyB64.length || textFormatting.count || !ddScan)) {
        return errorResponse(requestId, @"Rich links do not support send modifiers");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (richLinkPreview) {
        NSString *serviceName = serviceNameForChat(chat, chatGuid).lowercaseString;
        if (!([serviceName isEqualToString:@"imessage"] ||
              [serviceName isEqualToString:@"imessagelite"])) {
            return errorResponse(requestId, @"Rich links require an iMessage chat");
        }
    }

    NSAttributedString *body = attributedBodyFromBase64(attributedBodyB64);
    if (!body) {
        if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
            body = buildFormattedAttributed(message, textFormatting, partIndex);
        } else {
            body = buildPlainAttributed(message, partIndex);
        }
    }
    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;

    NSRange zeroRange = NSMakeRange(0, body.length);
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    // Reply targets need a derived thread identifier on macOS 26 to render
    // as a threaded in-line reply rather than a standalone message.
    // Best-effort: if we can't derive the parent, retain the older associated-message
    // fallback so receivers can still render a quoted reply.
    id parentMessage = nil;
    id parentItem = nil;
    NSString *threadIdentifier = nil;
    if (selectedMessageGuid.length) {
        threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                  &parentMessage,
                                                  &parentItem);
        debugLog(@"handleSendMessage: parent=%@ threadId=%@",
                 selectedMessageGuid, threadIdentifier ?: @"(none)");
    } else {
        clearThreadContextForChat(chat, nil);
    }

    NSString *richLinkSnapshotPath = nil;
    IMFileTransfer *richLinkTransfer = nil;
    BOOL richLinkTransferRegistered = NO;
    @try {
        id imMessage = nil;
        BOOL richLinkImageUsed = NO;
        if (richLinkPreview) {
            NSString *urlError = nil;
            NSURL *originalURL = validatedRichLinkURL(richLinkPreview[@"originalURL"], &urlError);
            if (!originalURL || ![message isEqualToString:originalURL.absoluteString]) {
                return errorResponse(requestId,
                    urlError.length ? urlError : @"Rich-link body does not match its URL");
            }
            body = annotateBodyForRichLink(body, originalURL.absoluteString);
            if (!body) {
                return errorResponse(requestId, @"Could not annotate rich-link body");
            }

            NSMutableArray *fileTransferGuids = [NSMutableArray array];
            NSString *previewMimeType = nil;
            NSURL *previewFile = nil;
            NSString *imageError = nil;
            NSDictionary *imageDescriptor = [richLinkPreview[@"image"]
                isKindOfClass:[NSDictionary class]] ? richLinkPreview[@"image"] : nil;
            if (richLinkPreview[@"image"] && !imageDescriptor) {
                return errorResponse(requestId, @"Invalid rich-link image descriptor");
            }
            if (!validateRichLinkPreviewImage(imageDescriptor,
                                              &previewFile,
                                              &previewMimeType,
                                              &imageError)) {
                return errorResponse(requestId, imageError ?: @"Invalid rich-link image");
            }
            if (previewFile) {
                richLinkSnapshotPath = previewFile.path;
                NSString *prepErr = nil;
                NSString *filename = previewFile.lastPathComponent;
                richLinkTransfer = prepareUnregisteredOutgoingTransfer(previewFile,
                                                                       filename,
                                                                       chatGuid,
                                                                       YES,
                                                                       previewMimeType,
                                                                       &prepErr);
                NSString *transferGuid = [richLinkTransfer guid];
                if (transferGuid.length) {
                    [fileTransferGuids addObject:transferGuid];
                    debugLog(@"rich-link: prepared hidden preview transfer");
                } else {
                    debugLog(@"rich-link: hidden preview unavailable (%@); using metadata-only card",
                             prepErr ?: @"unknown");
                    removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                    richLinkSnapshotPath = nil;
                    richLinkTransfer = nil;
                }
            }
            NSString *payloadError = nil;
            BOOL imageSubstituteInstalled = NO;
            NSData *payloadData = buildURLPreviewPayloadData(richLinkPreview,
                                                             fileTransferGuids.count > 0,
                                                             previewMimeType,
                                                             &imageSubstituteInstalled,
                                                             &payloadError);
            if (!payloadData) {
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                return errorResponse(requestId,
                    payloadError.length ? payloadError : @"Could not build URL preview payload");
            }
            if (fileTransferGuids.count > 0 && !imageSubstituteInstalled) {
                [fileTransferGuids removeAllObjects];
                richLinkTransfer = nil;
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                debugLog(@"rich-link: image substitute unavailable; using metadata-only card");
            }
            NSDictionary *summaryInfo = @{
                @"enc": @YES,
                @"eogcd": @3,
                @"ust": @YES
            };
            imMessage = buildBalloonIMMessage(urlPreviewBalloonBundleIdentifier(),
                                              body,
                                              payloadData,
                                              summaryInfo,
                                              fileTransferGuids,
                                              threadIdentifier,
                                              selectedMessageGuid,
                                              parentMessage && [parentMessage respondsToSelector:@selector(guid)]
                                                ? [parentMessage performSelector:@selector(guid)]
                                                : nil,
                                              nil,
                                              parentItem);
        } else {
            imMessage = buildIMMessage(body, subjectAttr,
                                       effectId,
                                       threadIdentifier,
                                       parentItem,
                                       selectedMessageGuid,
                                       associatedType,
                                       zeroRange,
                                       /*summaryInfo*/ nil,
                                       /*fileTransferGuids*/ @[],
                                       /*isAudio*/ NO,
                                       ddScan);
        }
        if (!imMessage) {
            removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
            richLinkSnapshotPath = nil;
            return errorResponse(requestId, @"Could not construct IMMessage");
        }
        if (richLinkTransfer) {
            NSString *registrationError = nil;
            if (!registerPreparedTransfer(richLinkTransfer, &registrationError)) {
                removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
                richLinkSnapshotPath = nil;
                return errorResponse(requestId,
                    registrationError ?: @"Could not register rich-link preview transfer");
            }
            richLinkTransferRegistered = YES;
            richLinkImageUsed = YES;
        }

        // IMCore exposes separate originator types: IMMessageItem wants the
        // parent item during item-first construction, while IMMessage wants
        // the parent message on the wrapped object.
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }

        if (gHasSendMessageReason && ddScan) {
            // Deferred-send path on macOS 13+: sleep 100ms, then call
            // `sendMessage:reason:` so the spam filter can run on the body.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                NSMethodSignature *sig = [chat methodSignatureForSelector:
                    @selector(sendMessage:reason:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(sendMessage:reason:)];
                [inv setTarget:chat];
                __unsafe_unretained id arg = imMessage;
                [inv setArgument:&arg atIndex:2];
                NSInteger reason = 0;
                [inv setArgument:&reason atIndex:3];
                [inv invoke];
            });
        } else {
            dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        }

        // Best-effort messageGuid; not always available immediately.
        NSString *guid = lastSentMessageGuid(chat);
        NSMutableDictionary *response = [@{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"queued": @(ddScan)
        } mutableCopy];
        NSString *serviceName = serviceNameForChat(chat, chatGuid);
        if (serviceName.length) response[@"service"] = serviceName;
        if (richLinkPreview) response[@"richLinkImageUsed"] = @(richLinkImageUsed);
        return successResponse(requestId, response);
    } @catch (NSException *exception) {
        if (!richLinkTransferRegistered) {
            removeRichLinkPreviewSnapshot(richLinkSnapshotPath);
        }
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-message failed: %@", exception.reason]);
    }
}

/// `send-poll`: construct a native Messages Polls extension balloon and send
/// it via IMCore. Payload shape mirrors Apple's Polls extension envelope:
/// archived layout metadata plus a data URL carrying the JSON poll definition.
static NSDictionary *handleSendPoll(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *question = trimmedPollString(params[@"question"]);
    NSArray *rawOptions = params[@"options"];
    NSString *creatorHandle = trimmedPollString(params[@"creatorHandle"]);
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!question.length) return errorResponse(requestId, @"Missing question");
    if (![rawOptions isKindOfClass:[NSArray class]]) {
        return errorResponse(requestId, @"Missing options array");
    }

    NSArray<NSString *> *options = normalizedPollOptions(rawOptions);
    if (options.count < 2) {
        return errorResponse(requestId, @"Poll requires at least two options");
    }
    if (!pollPayloadMessageInitializerAvailable()) {
        return errorResponse(requestId, @"Poll IMMessage initializer unavailable on this macOS");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    if (!creatorHandle.length) {
        creatorHandle = activeIMessageSenderHandle();
    }
    if (!creatorHandle.length) {
        return errorResponse(requestId,
            @"Could not resolve active iMessage sender handle for poll payload");
    }

    NSString *sessionIdentifier = nil;
    NSArray<NSString *> *optionIdentifiers = nil;
    NSString *payloadError = nil;
    NSData *payloadData = buildPollCreationPayloadData(question,
                                                       options,
                                                       creatorHandle,
                                                       &sessionIdentifier,
                                                       &optionIdentifiers,
                                                       &payloadError);
    if (!payloadData) {
        return errorResponse(requestId, payloadError ?: @"Could not build poll payload");
    }

    NSDictionary *summary = @{ @"enc": @YES, @"ust": @YES };
    NSAttributedString *body = buildPollBreadcrumbAttributed();
    id parentMessage = nil;
    id parentItem = nil;
    id parentChatItem = nil;
    NSString *threadIdentifier = nil;
    NSString *threadOriginatorPart = nil;
    NSString *replyToGUID = selectedMessageGuid;
    NSString *threadOriginatorGUID = selectedMessageGuid;
    if (selectedMessageGuid.length) {
        threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                  &parentMessage,
                                                  &parentItem);
        parentChatItem = loadParentFirstChatItem(selectedMessageGuid, NULL);
        threadOriginatorPart = threadOriginatorPartForChatItem(parentChatItem ?: parentItem);
        debugLog(@"handleSendPoll: parent=%@ threadId=%@",
                 selectedMessageGuid, threadIdentifier ?: @"(none)");
        if (!threadIdentifier.length || !parentMessage || !parentItem) {
            return errorResponse(requestId,
                [NSString stringWithFormat:
                    @"Could not resolve reply target for poll: %@", selectedMessageGuid]);
        }
    } else {
        clearThreadContextForChat(chat, nil);
    }

    @try {
        id imMessage = buildPollIMMessage(body,
                                          payloadData,
                                          summary,
                                          threadIdentifier,
                                          replyToGUID,
                                          threadOriginatorGUID,
                                          threadOriginatorPart,
                                          parentItem);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct poll IMMessage");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        applyThreadOriginatorGUIDHints(imMessage,
                                       selectedMessageGuid,
                                       threadOriginatorPart);
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = lastSentMessageGuid(chat);

        NSMutableArray *optionPayloads = [NSMutableArray array];
        for (NSUInteger i = 0; i < options.count; i++) {
            NSString *identifier = optionIdentifiers.count > i ? optionIdentifiers[i] : @"";
            [optionPayloads addObject:@{@"id": identifier, @"text": options[i]}];
        }

        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"poll": @{
                @"kind": @"created",
                @"event": @"imessage.poll.created",
                @"question": question,
                @"options": optionPayloads,
                @"sessionIdentifier": sessionIdentifier ?: @""
            },
            @"balloonBundleID": pollsBalloonBundleIdentifier()
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-poll failed: %@", exception.reason]);
    }
}

/// Build the vote payload: a data URL carrying the vote JSON, wrapped in the
/// same archived envelope as poll creation. Mirrors Apple's native vote shape
/// (verified against a real received vote): {"version":1,"item":{"votes":
/// [{"voteOptionIdentifier":...,"participantHandle":...}]}}. Unlike poll
/// creation the data URL carries no `?src=p&c=` suffix.
static NSData *buildPollVotePayloadData(NSString *optionIdentifier,
                                        NSString *voterHandle,
                                        NSArray<NSString *> *remainingOptionIdentifiers,
                                        BOOL removed,
                                        NSString **outError) {
    NSArray<NSString *> *voteOptionIdentifiers = removed
        ? (remainingOptionIdentifiers ?: @[])
        : @[(optionIdentifier ?: @"")];
    NSMutableArray *votes = [NSMutableArray arrayWithCapacity:voteOptionIdentifiers.count];
    NSString *participantHandle = pollParticipantHandle(voterHandle) ?: @"";
    for (NSString *identifierValue in voteOptionIdentifiers) {
        NSString *identifier = trimmedPollString(identifierValue);
        if (!identifier.length) {
            if (outError) *outError = @"Poll vote payload contains an empty option identifier";
            return nil;
        }
        [votes addObject:@{
            @"voteOptionIdentifier": identifier,
            @"participantHandle": participantHandle
        }];
    }
    NSDictionary *root = @{
        @"version": @1,
        @"item": @{ @"votes": votes }
    };
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!jsonData) {
        if (outError) *outError = jsonError.localizedDescription ?: @"Could not encode vote payload";
        return nil;
    }
    if (jsonData.length > 4096) {
        if (outError) *outError = @"Poll vote payload exceeds 4096 bytes";
        return nil;
    }
    NSString *encoded = [jsonData base64EncodedStringWithOptions:0];
    NSString *urlString = [NSString stringWithFormat:@"data:,%@", encoded];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = @"Could not create vote URL";
        return nil;
    }
    NSUUID *sessionIdentifier = [NSUUID UUID];
    NSError *archiveError = nil;
    NSData *payload = archivePollMutationEnvelope(url, sessionIdentifier, &archiveError);
    if (!payload && outError) {
        *outError = archiveError.localizedDescription ?: @"Could not archive vote payload";
    }
    return payload;
}

/// Construct a poll-vote IMMessage: a Polls balloon carrying the vote payload,
/// associated to the original poll via a bare poll GUID + associatedMessageType
/// 4000. Native votes (verified against chat.db) use a bare poll GUID, not the
/// `p:<part>/<guid>` form tapbacks use.
///
/// The associated-message initializer persists the poll link atomically. Its
/// backing item then receives the balloon payload; wrapping an item first loses
/// the association on macOS 26.
static id buildPollVoteIMMessage(NSAttributedString *body,
                                 NSData *payloadData,
                                 NSDictionary *summaryInfo,
                                 NSString *pollMessageGuid,
                                 long long associatedType) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;

    // No macOS 26 initializer carries the payload and association together.
    // Build the association atomically, then stamp payload metadata across the
    // message and backing item; macOS 26.4 splits the setters between them.
    SEL sel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
    if (![messageClass instancesRespondToSelector:sel]) return nil;

    id msg = [messageClass alloc];
    NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:msg];

    id nilObj = nil;
    NSDate *now = [NSDate date];
    NSArray *fileTransferGuids = @[];
    unsigned long long flags = flagsForAssociatedMessagePayload(nil, fileTransferGuids, NO);
    NSRange associatedRange = NSMakeRange(0, 1);

    [inv setArgument:&nilObj atIndex:2];            // sender
    [inv setArgument:&now atIndex:3];               // time
    [inv setArgument:&body atIndex:4];              // text
    [inv setArgument:&nilObj atIndex:5];            // messageSubject
    [inv setArgument:&fileTransferGuids atIndex:6];
    [inv setArgument:&flags atIndex:7];
    [inv setArgument:&nilObj atIndex:8];            // error
    [inv setArgument:&nilObj atIndex:9];            // guid
    [inv setArgument:&nilObj atIndex:10];           // subject (string)
    [inv setArgument:&pollMessageGuid atIndex:11];
    [inv setArgument:&associatedType atIndex:12];
    [inv setArgument:&associatedRange atIndex:13];
    [inv setArgument:&summaryInfo atIndex:14];
    [inv retainArguments];
    id result = invokeReturningObject(inv);
    if (!result) return nil;

    NSString *balloonID = pollsBalloonBundleIdentifier();
    NSArray<id> *targets = @[result];
    SEL itemSel = NSSelectorFromString(@"_imMessageItem");
    if ([result respondsToSelector:itemSel]) {
        @try {
            id item = [result performSelector:itemSel];
            if (item) targets = @[item, result];
        } @catch (__unused NSException *e) {}
    }
    BOOL balloonStamped = NO;
    BOOL payloadStamped = NO;
    for (id target in targets) {
        if ([target respondsToSelector:@selector(setBalloonBundleID:)]) {
            [target performSelector:@selector(setBalloonBundleID:) withObject:balloonID];
            balloonStamped = YES;
        }
        if ([target respondsToSelector:@selector(setPayloadData:)]) {
            [target performSelector:@selector(setPayloadData:) withObject:payloadData];
            payloadStamped = YES;
        }
    }
    return (balloonStamped && payloadStamped) ? result : nil;
}

static NSDictionary *handleSendPollVoteMutation(NSInteger requestId,
                                                NSDictionary *params,
                                                BOOL removed) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *pollMessageGuid = trimmedPollString(params[@"pollMessageGuid"]);
    NSString *optionIdentifier = trimmedPollString(params[@"optionIdentifier"]);
    NSString *optionText = trimmedPollString(params[@"optionText"]);
    NSArray *remainingOptionIdentifiers = @[];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!pollMessageGuid.length) return errorResponse(requestId, @"Missing pollMessageGuid");
    if (!optionIdentifier.length) return errorResponse(requestId, @"Missing optionIdentifier");
    if (removed) {
        id rawRemaining = params[@"remainingOptionIdentifiers"];
        if (rawRemaining && ![rawRemaining isKindOfClass:[NSArray class]]) {
            return errorResponse(requestId, @"remainingOptionIdentifiers must be an array");
        }
        NSMutableArray *normalizedRemaining = [NSMutableArray array];
        for (id rawIdentifier in (NSArray *)(rawRemaining ?: @[])) {
            if (![rawIdentifier isKindOfClass:[NSString class]]) {
                return errorResponse(requestId, @"remainingOptionIdentifiers must contain strings");
            }
            NSString *identifier = trimmedPollString(rawIdentifier);
            if (!identifier.length) {
                return errorResponse(requestId, @"remainingOptionIdentifiers must not contain empty values");
            }
            [normalizedRemaining addObject:identifier];
        }
        remainingOptionIdentifiers = [normalizedRemaining copy];
    }
    if (!pollVoteMessageInitializerAvailable()) {
        return errorResponse(requestId, @"Poll vote IMMessage initializer unavailable on this macOS");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSString *voterHandle = activeIMessageSenderHandle();
    if (!voterHandle.length) {
        return errorResponse(requestId,
            @"Could not resolve active iMessage sender handle for vote payload");
    }

    NSString *payloadError = nil;
    NSData *payloadData = buildPollVotePayloadData(optionIdentifier,
                                                   voterHandle,
                                                   remainingOptionIdentifiers,
                                                   removed,
                                                   &payloadError);
    if (!payloadData) {
        return errorResponse(requestId, payloadError ?: @"Could not build vote payload");
    }

    NSDictionary *summary = @{
        @"amc": @9,
        @"enc": @YES,
        @"amd": @"Polls",
        @"ust": @YES,
        @"ams": @"Sent a vote",
        @"amb": pollsBalloonBundleIdentifier()
    };
    NSAttributedString *body = buildPollBreadcrumbAttributed();

    @try {
        clearThreadContextForChat(chat, nil);
        id imMessage = buildPollVoteIMMessage(body, payloadData, summary, pollMessageGuid, 4000);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct vote IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"pollMessageGuid": pollMessageGuid,
            @"optionIdentifier": optionIdentifier,
            @"optionText": optionText ?: @"",
            @"remainingOptionIdentifiers": remainingOptionIdentifiers,
            @"removed": @(removed),
            @"balloonBundleID": pollsBalloonBundleIdentifier()
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-poll-vote failed: %@", exception.reason]);
    }
}

/// `send-poll-vote`: cast a vote on an existing poll. Builds a Polls balloon
/// carrying the vote payload, associated to the poll message via type 4000.
/// The caller passes the original poll message GUID and the chosen option's
/// UUID (resolved CLI-side from the poll's decoded options).
static NSDictionary *handleSendPollVote(NSInteger requestId, NSDictionary *params) {
    return handleSendPollVoteMutation(requestId, params, NO);
}

/// `send-poll-unvote`: remove one selected option by sending the same native
/// vote payload shape with the sender's remaining selected options.
static NSDictionary *handleSendPollUnvote(NSInteger requestId, NSDictionary *params) {
    return handleSendPollVoteMutation(requestId, params, YES);
}

/// `send-multipart`: at minimum, sends an attributedBody composed of multiple
/// text parts. v1 supports text-only multipart; mention/file parts can land in
/// a follow-up.
static NSDictionary *handleSendMultipart(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSArray *parts = params[@"parts"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) {
        return errorResponse(requestId, @"Missing or empty parts array");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSInteger partIndex = 0;
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = part[@"text"];
        if (!text.length) continue;
        NSArray *partFormatting = part[@"textFormatting"];
        NSAttributedString *seg;
        if ([partFormatting isKindOfClass:[NSArray class]] && partFormatting.count > 0) {
            seg = buildFormattedAttributed(text, partFormatting, partIndex);
        } else {
            seg = buildPlainAttributed(text, partIndex);
        }
        [body appendAttributedString:seg];
        partIndex++;
    }
    if (body.length == 0) {
        return errorResponse(requestId, @"No usable parts");
    }

    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    @try {
        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendMultipart: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }
        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length),
                                      nil, @[], NO, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct multipart IMMessage");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"parts_count": @(partIndex)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
}

/// Build an attachment-bearing attributed string. The placeholder is an OBJ
/// replacement character (￼) tagged with the IMCore attachment attributes
/// (`__kIMFileTransferGUIDAttributeName`, `__kIMFilenameAttributeName`,
/// `__kIMMessagePartAttributeName`, `__kIMBaseWritingDirectionAttributeName`).
/// Without these attributes Messages.app sends an empty-body message and never
/// links the attachment row in chat.db.
static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex) {
    NSDictionary *attrs = @{
        @"__kIMBaseWritingDirectionAttributeName": @"-1",
        @"__kIMFileTransferGUIDAttributeName": transferGuid ?: @"",
        @"__kIMFilenameAttributeName": filename ?: @"",
        @"__kIMMessagePartAttributeName": @(partIndex),
    };
    return [[NSAttributedString alloc] initWithString:@"￼" attributes:attrs];
}

static void setIntegerProperty(id object, SEL selector, NSInteger value) {
    if (!object || ![object respondsToSelector:selector]) return;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:selector];
    [inv setTarget:object];
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}

static const unsigned long long kMaxStickerBytes = 500ULL * 1024ULL;
static const NSUInteger kMaxStickerDimension = 618;
static const NSUInteger kMaxStickerFrames = 100;
static const unsigned long long kMaxStickerDecodedPixels = 25000000ULL;
static NSString * const kDefaultStickerParentPreviewWidth = @"163.73095703";

static NSString *actualUserHomeDirectory(void) {
    struct passwd *entry = getpwuid(getuid());
    if (!entry || !entry->pw_dir) return nil;
    return [NSString stringWithUTF8String:entry->pw_dir];
}

static NSString *trustedMessagesAttachmentsRoot(void) {
    return [actualUserHomeDirectory()
        stringByAppendingPathComponent:@"Library/Messages/Attachments"];
}

static NSString *trustedStickerRoot(void) {
    return [trustedMessagesAttachmentsRoot()
        stringByAppendingPathComponent:@"imsg/stickers"];
}

static BOOL pathIsWithinRoot(NSString *path, NSString *root) {
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) return NO;
    NSString *candidate = [path stringByStandardizingPath];
    NSString *standardRoot = [root stringByStandardizingPath];
    return standardRoot.length
        && [candidate hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static BOOL stickerPathIsTrusted(NSString *path) {
    return pathIsWithinRoot(path, trustedStickerRoot());
}

static int openUserOwnedDirectorySecurely(NSString *directoryPath,
                                          NSString *requiredRoot) {
    NSString *root = [requiredRoot stringByStandardizingPath];
    NSString *directory = [directoryPath stringByStandardizingPath];
    if (!root.length || !directory.length) return -1;
    if (![directory isEqualToString:root]
        && ![directory hasPrefix:[root stringByAppendingString:@"/"]]) {
        return -1;
    }

    NSString *home = [actualUserHomeDirectory() stringByStandardizingPath];
    if (!home.length || ![root hasPrefix:[home stringByAppendingString:@"/"]]) return -1;
    int directoryFD = open(home.fileSystemRepresentation,
                           O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (directoryFD < 0) return -1;
    struct stat homeInfo = {0};
    if (fstat(directoryFD, &homeInfo) != 0 || !S_ISDIR(homeInfo.st_mode)
        || homeInfo.st_uid != getuid() || (homeInfo.st_mode & S_IWOTH)) {
        close(directoryFD);
        return -1;
    }
    NSString *relative = [directory substringFromIndex:home.length + 1];
    NSArray<NSString *> *components = relative.pathComponents;
    for (NSString *component in components) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]
            || [component isEqualToString:@"/"] || component.length == 0) {
            close(directoryFD);
            return -1;
        }
        int nextFD = openat(directoryFD, component.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
        close(directoryFD);
        if (nextFD < 0) return -1;
        struct stat componentInfo = {0};
        if (fstat(nextFD, &componentInfo) != 0 || !S_ISDIR(componentInfo.st_mode)
            || componentInfo.st_uid != getuid() || (componentInfo.st_mode & S_IWOTH)) {
            close(nextFD);
            return -1;
        }
        directoryFD = nextFD;
    }
    return directoryFD;
}

static int openStickerDirectorySecurely(NSString *directoryPath) {
    return openUserOwnedDirectorySecurely(directoryPath, trustedStickerRoot());
}

static int openStickerTransferDirectorySecurely(NSString *directoryPath) {
    return openUserOwnedDirectorySecurely(
        directoryPath, trustedMessagesAttachmentsRoot());
}

static NSData *readStickerSnapshot(NSString *path, NSString **outErr) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryFD = openStickerDirectorySecurely(directory);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open sticker directory";
        return nil;
    }
    int fd = openat(directoryFD, path.lastPathComponent.fileSystemRepresentation,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    close(directoryFD);
    if (fd < 0) {
        if (outErr) *outErr = @"Could not securely open sticker image";
        return nil;
    }
    struct stat before = {0};
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_nlink != 1) {
        close(fd);
        if (outErr) *outErr = @"Sticker must be a single-link regular file";
        return nil;
    }
    if (before.st_size <= 0 || (unsigned long long)before.st_size > kMaxStickerBytes) {
        close(fd);
        if (outErr) {
            *outErr = [NSString stringWithFormat:
                @"Sticker image must be between 1 byte and %llu bytes", kMaxStickerBytes];
        }
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)before.st_size];
    unsigned char buffer[64 * 1024];
    while (YES) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd);
            if (outErr) *outErr = @"Could not read sticker image";
            return nil;
        }
        if ((unsigned long long)data.length + (unsigned long long)count
            > kMaxStickerBytes) {
            close(fd);
            if (outErr) *outErr = @"Sticker image exceeded the size limit while reading";
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    struct stat after = {0};
    BOOL changed = fstat(fd, &after) != 0
        || after.st_dev != before.st_dev
        || after.st_ino != before.st_ino
        || after.st_size != before.st_size
        || after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec
        || after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec
        || after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
        || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec;
    close(fd);
    if (changed || data.length != (NSUInteger)before.st_size) {
        if (outErr) *outErr = @"Sticker file changed while it was being read";
        return nil;
    }
    return data;
}

static NSString *stickerSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSString *stickerMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL stickerContainerIsComplete(NSData *data, NSString *uti) {
    const unsigned char *bytes = data.bytes;
    if ([uti isEqualToString:@"public.png"]) {
        static const unsigned char iend[] = {
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        };
        return data.length >= sizeof(iend)
            && memcmp(bytes + data.length - sizeof(iend), iend, sizeof(iend)) == 0;
    }
    if ([uti isEqualToString:@"com.compuserve.gif"]) {
        return data.length > 0 && bytes[data.length - 1] == 0x3b;
    }
    if ([uti isEqualToString:@"public.jpeg"]) {
        return data.length >= 2
            && bytes[data.length - 2] == 0xff
            && bytes[data.length - 1] == 0xd9;
    }
    return NO;
}

static NSDictionary *stickerAssetMetadata(NSString *path, NSString **outErr) {
    if (!stickerPathIsTrusted(path) || pathHasSymlinkComponent(path)) {
        if (outErr) *outErr = @"Sticker must use imsg's trusted staging directory";
        return nil;
    }
    NSData *data = readStickerSnapshot(path, outErr);
    if (!data) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        if (outErr) *outErr = @"Sticker file is not a decodable image";
        return nil;
    }
    NSUInteger frameCount = CGImageSourceGetCount(source);
    if (frameCount == 0 || frameCount > kMaxStickerFrames) {
        if (source) CFRelease(source);
        if (outErr) {
            *outErr = [NSString stringWithFormat:
                @"Sticker must contain 1...%lu frames", (unsigned long)kMaxStickerFrames];
        }
        return nil;
    }
    NSString *uti = (__bridge NSString *)CGImageSourceGetType(source);
    NSSet *supportedTypes = [NSSet setWithObjects:
        @"public.png", @"com.compuserve.gif", @"public.jpeg", nil];
    if (![supportedTypes containsObject:uti]) {
        CFRelease(source);
        if (outErr) {
            *outErr = [NSString stringWithFormat:
                @"Unsupported sticker image format: %@", uti ?: @"unknown"];
        }
        return nil;
    }
    if (!stickerContainerIsComplete(data, uti)) {
        CFRelease(source);
        if (outErr) *outErr = @"Sticker image data is incomplete";
        return nil;
    }
    NSUInteger firstWidth = 0;
    NSUInteger firstHeight = 0;
    unsigned long long decodedPixels = 0;
    for (NSUInteger index = 0; index < frameCount; index++) {
        CFDictionaryRef rawProperties =
            CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
        if (!rawProperties) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker file contains invalid frame metadata";
            return nil;
        }
        NSDictionary *properties = CFBridgingRelease(rawProperties);
        NSUInteger width =
            [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        NSUInteger height =
            [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        if (width == 0 || height == 0 || width > kMaxStickerDimension
            || height > kMaxStickerDimension) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker image dimensions are invalid or too large";
            return nil;
        }
        if (index == 0) {
            firstWidth = width;
            firstHeight = height;
        }
        decodedPixels += (unsigned long long)width * (unsigned long long)height;
        if (decodedPixels > kMaxStickerDecodedPixels) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker animation contains too many decoded pixels";
            return nil;
        }
        CGImageRef frame = CGImageSourceCreateImageAtIndex(source, index, NULL);
        if (!frame) {
            CFRelease(source);
            if (outErr) *outErr = @"Sticker file contains an undecodable frame";
            return nil;
        }
        CGImageRelease(frame);
    }
    CFRelease(source);
    NSString *hash = stickerSHA256(data);
    NSString *md5 = stickerMD5(data);
    NSString *extension = [uti isEqualToString:@"public.png"] ? @"png"
        : ([uti isEqualToString:@"public.jpeg"] ? @"jpg" : @"gif");
    return @{
        @"data": data,
        @"extension": extension,
        @"hash": hash,
        @"md5": md5,
        @"width": @(firstWidth),
        @"height": @(firstHeight),
        @"uti": uti,
    };
}

static NSString *writeStickerSnapshot(NSDictionary *metadata, NSString *sourcePath,
                                      NSString **outErr) {
    NSData *data = metadata[@"data"];
    NSString *hash = metadata[@"hash"];
    NSString *extension = metadata[@"extension"];
    if (!data.length || !hash.length || !extension.length) {
        if (outErr) *outErr = @"Missing validated sticker snapshot";
        return nil;
    }
    NSString *directory = [sourcePath stringByDeletingLastPathComponent];
    NSString *name = [NSString stringWithFormat:@"%@.%@", hash, extension];
    NSString *path = [directory stringByAppendingPathComponent:name];
    int directoryFD = openStickerDirectorySecurely(directory);
    if (directoryFD < 0) {
        if (outErr) *outErr = @"Could not securely open sticker directory";
        return nil;
    }
    int fd = openat(directoryFD, name.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        close(directoryFD);
        if (outErr) *outErr = @"Could not create private sticker snapshot";
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    BOOL ok = YES;
    while (offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    struct stat descriptorInfo = {0};
    struct stat pathInfo = {0};
    if (ok && fstat(fd, &descriptorInfo) != 0) ok = NO;
    if (ok && (lstat(path.fileSystemRepresentation, &pathInfo) != 0
        || pathInfo.st_dev != descriptorInfo.st_dev
        || pathInfo.st_ino != descriptorInfo.st_ino
        || !S_ISREG(pathInfo.st_mode))) ok = NO;
    if (close(fd) != 0) ok = NO;
    if (!ok) {
        unlinkat(directoryFD, name.fileSystemRepresentation, 0);
        close(directoryFD);
        if (outErr) *outErr = @"Could not write private sticker snapshot";
        return nil;
    }
    close(directoryFD);
    return path;
}

static BOOL removeStickerFileSecurely(NSString *path) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryFD = openStickerDirectorySecurely(directory);
    if (directoryFD < 0) return NO;
    int result = unlinkat(
        directoryFD, path.lastPathComponent.fileSystemRepresentation, 0);
    int savedErrno = errno;
    close(directoryFD);
    return result == 0 || savedErrno == ENOENT;
}

static BOOL removeStickerTransferFileSecurely(NSString *path) {
    if (!pathIsWithinRoot(path, trustedMessagesAttachmentsRoot())) return NO;
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryFD = openStickerTransferDirectorySecurely(directory);
    if (directoryFD < 0) return NO;
    int result = unlinkat(
        directoryFD, path.lastPathComponent.fileSystemRepresentation, 0);
    int savedErrno = errno;
    close(directoryFD);
    return result == 0 || savedErrno == ENOENT;
}

static BOOL stickerMessageBelongsToChat(IMChat *chat, NSString *messageGuid) {
    SEL selector = NSSelectorFromString(@"hasStoredMessageWithGUID:");
    if (!chat || !messageGuid.length || ![chat respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(chat, selector, messageGuid);
}

static NSDictionary *stickerUserInfo(NSDictionary *metadata) {
    NSString *hash = metadata[@"hash"];
    NSString *md5 = metadata[@"md5"];
    NSString *filename = metadata[@"filename"];
    return @{
        @"pid": @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension",
        @"safi": @0,
        @"sai": @"0",
        // Apple uses MD5 for the sticker hash and the source basename for the
        // sticker GUID. Integrity still uses the out-of-band SHA-256 above.
        @"shash": md5,
        @"sid": filename,
        @"sli": @"0",
        @"spv": @0,
        // Native user-generated stickers include the target preview width in
        // this geometry tuple. Until a stable target-layout selector is known,
        // retain the proven centered default rather than misusing image width.
        @"spw": kDefaultStickerParentPreviewWidth,
        @"sro": @"0.00000000",
        @"ssa": @"1.00000000",
        @"stickerEffectType": @(-1),
        @"suri": [NSString stringWithFormat:@"sticker:///imsg/%@", hash],
        @"sxs": @"0.50000000",
        @"sys": @"0.50000000"
    };
}

static NSDictionary *stickerAttributionInfo(NSString *accessibilityLabel,
                                             NSDictionary *metadata) {
    NSString *label = [[accessibilityLabel componentsSeparatedByCharactersInSet:
        [NSCharacterSet controlCharacterSet]] componentsJoinedByString:@" "];
    label = [label stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!label.length) label = @"Sticker";
    if (label.length > 150) {
        NSRange safeRange = [label rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 150)];
        label = [label substringWithRange:safeRange];
    }
    return @{
        @"accessl": label,
        @"bundle-id": @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension",
        @"name": @"Stickers",
        @"pgensh": metadata[@"height"] ?: @0,
        @"pgensw": metadata[@"width"] ?: @0,
        @"pgenszc": @{
            @"gm": @NO,
            @"iaig": @NO,
            @"mpw": @"600.000000",
            @"mth": @"100.000000",
            @"mtw": @"100.000000",
            @"s": @"1.000000",
            @"st": @NO
        }
    };
}

static BOOL markTransferAsSticker(IMFileTransfer *transfer,
                                  NSString *accessibilityLabel,
                                  NSDictionary *metadata,
                                  NSString **outErr) {
    if (!transfer) {
        if (outErr) *outErr = @"Missing transfer";
        return NO;
    }
    if (![transfer respondsToSelector:@selector(setIsSticker:)]
        || ![transfer respondsToSelector:@selector(setStickerUserInfo:)]
        || ![transfer respondsToSelector:@selector(setAttributionInfo:)]) {
        if (outErr) *outErr = @"Required IMFileTransfer sticker selectors unavailable";
        return NO;
    }
    BOOL yes = YES;
    NSMethodSignature *sig = [transfer methodSignatureForSelector:@selector(setIsSticker:)];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:@selector(setIsSticker:)];
    [inv setTarget:transfer];
    [inv setArgument:&yes atIndex:2];
    [inv invoke];
    NSDictionary *stickerInfo = stickerUserInfo(metadata);
    [transfer performSelector:@selector(setStickerUserInfo:) withObject:stickerInfo];
    [transfer performSelector:@selector(setAttributionInfo:)
                   withObject:stickerAttributionInfo(accessibilityLabel, metadata)];
    setIntegerProperty(transfer, @selector(setPreviewGenerationState:), 1);
    setIntegerProperty(transfer, @selector(setPreviewGenerationVersion:), 1);
    return YES;
}

static NSAttributedString *annotateBodyForRichLink(NSAttributedString *body,
                                                   NSString *urlString) {
    if (!body.length || !urlString.length) return body;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return body;
    NSMutableAttributedString *annotated = [body mutableCopy];
    NSString *plain = annotated.string ?: @"";
    NSRange range = [plain rangeOfString:urlString];
    if (range.location == NSNotFound || range.length == 0 ||
        range.location != 0 || range.length != annotated.length) return nil;
    [annotated addAttribute:@"__kIMLinkAttributeName" value:url range:range];
    [annotated addAttribute:@"__kIMLinkIsRichLinkAttributeName" value:@YES range:range];
    [annotated addAttribute:NSLinkAttributeName value:url range:range];
    return annotated;
}

/// Register an outgoing file transfer with IMFileTransferCenter so that
/// Messages.app/imagent persists the attachment row and links it back to the
/// outbound message. Mirrors BlueBubblesHelper's `prepareFileTransferForAttachment`:
///   1. Allocate a guid via `guidForNewOutgoingTransferWithLocalURL:`.
///   2. Resolve the resulting `IMFileTransfer` via `transferForGUID:`.
///   3. Stage the source file in the IMD-managed attachments tree.
///   4. `retargetTransfer:toPath:` + `setLocalURL:` to point the transfer at
///      the staged copy.
/// The caller registers the prepared transfer only after message construction
/// succeeds, avoiding daemon-visible orphan transfers on builder failures.
/// On failure returns `nil`; the caller emits the error.
static BOOL retargetPreparedTransfer(id ftc, IMFileTransfer *transfer,
                                     NSString *transferGuid, NSString *path) {
    if (!path.length) return NO;
    // Updating only `localURL` is not enough: IMFileTransferCenter keeps its
    // own guid -> path map, and imagent reads that map when daemon registration
    // happens.
    BOOL retargetedCenter = [ftc respondsToSelector:@selector(retargetTransfer:toPath:)];
    if (retargetedCenter) {
        NSMethodSignature *rsig = [ftc methodSignatureForSelector:
            @selector(retargetTransfer:toPath:)];
        NSInvocation *rinv = [NSInvocation invocationWithMethodSignature:rsig];
        [rinv setSelector:@selector(retargetTransfer:toPath:)];
        [rinv setTarget:ftc];
        __unsafe_unretained NSString *g = transferGuid;
        __unsafe_unretained NSString *p = path;
        [rinv setArgument:&g atIndex:2];
        [rinv setArgument:&p atIndex:3];
        [rinv invoke];
    }
    if ([transfer respondsToSelector:@selector(setLocalURL:)]) {
        [transfer performSelector:@selector(setLocalURL:)
                       withObject:[NSURL fileURLWithPath:path]];
    }
    return retargetedCenter;
}

static BOOL pathsReferToSameFile(NSString *lhs, NSString *rhs) {
    if (!lhs.length || !rhs.length) return NO;
    if ([lhs.stringByStandardizingPath isEqualToString:rhs.stringByStandardizingPath]) {
        return YES;
    }
    struct stat leftInfo = {0};
    struct stat rightInfo = {0};
    return stat(lhs.fileSystemRepresentation, &leftInfo) == 0
        && stat(rhs.fileSystemRepresentation, &rightInfo) == 0
        && leftInfo.st_dev == rightInfo.st_dev
        && leftInfo.st_ino == rightInfo.st_ino;
}

static BOOL configurePreviewPayloadTransfer(IMFileTransfer *transfer,
                                            NSString *mimeType,
                                            NSString *filename) {
    if (!transfer || !mimeType.length || !filename.length ||
        ![transfer respondsToSelector:@selector(setHideAttachment:)] ||
        ![transfer respondsToSelector:@selector(setMimeType:)] ||
        ![transfer respondsToSelector:@selector(setTransferredFilename:)]) {
        return NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transfer,
                                            @selector(setHideAttachment:),
                                            YES);
    [transfer performSelector:@selector(setMimeType:) withObject:mimeType];
    [transfer performSelector:@selector(setTransferredFilename:) withObject:filename];
    return YES;
}

static IMFileTransfer *prepareOutgoingTransfer(NSURL *originalURL, NSString *filename,
                                               NSString *chatGuid,
                                               IMsgOutgoingTransferKind transferKind,
                                               NSDictionary *transferMetadata,
                                               NSString **outActivePath,
                                               NSString **outErr) {
    if (outActivePath) *outActivePath = originalURL.path;
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    if (!ftcClass) {
        if (outErr) *outErr = @"IMFileTransferCenter not available";
        return nil;
    }
    id ftc = [ftcClass performSelector:@selector(sharedInstance)];
    if (!ftc) {
        if (outErr) *outErr = @"FileTransferCenter unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(guidForNewOutgoingTransferWithLocalURL:)]) {
        if (outErr) *outErr = @"guidForNewOutgoingTransferWithLocalURL: unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(transferForGUID:)]) {
        if (outErr) *outErr = @"transferForGUID: unavailable";
        return nil;
    }
    if (![ftc respondsToSelector:@selector(registerTransferWithDaemon:)]) {
        if (outErr) *outErr = @"registerTransferWithDaemon: unavailable";
        return nil;
    }

    id rawGuid = [ftc performSelector:@selector(guidForNewOutgoingTransferWithLocalURL:)
                           withObject:originalURL];
    if (![rawGuid isKindOfClass:[NSString class]] || ![(NSString *)rawGuid length]) {
        if (outErr) *outErr = @"Could not allocate transfer guid";
        return nil;
    }
    NSString *transferGuid = (NSString *)rawGuid;

    IMFileTransfer *transfer =
        [ftc performSelector:@selector(transferForGUID:) withObject:transferGuid];
    if (!transfer) {
        if (outErr) *outErr = @"Could not resolve IMFileTransfer for guid";
        return nil;
    }

    // Try to copy the source file into the IMD-managed attachments tree and
    // retarget the transfer. macOS 26 returns nil here if `chatGUID` is nil;
    // passing the real chat GUID is what gives IMD enough context to choose the
    // per-chat attachment-store path that Messages/imagent will accept.
    Class pacClass = NSClassFromString(@"IMDPersistentAttachmentController");
    if (pacClass && transferKind != IMsgOutgoingTransferKindRichLinkPreview) {
        id pac = [pacClass performSelector:@selector(sharedInstance)];
        SEL pathSel = @selector(_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:);
        if (pac && [pac respondsToSelector:pathSel]) {
            NSMethodSignature *sig = [pac methodSignatureForSelector:pathSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:pathSel];
            [inv setTarget:pac];
            __unsafe_unretained IMFileTransfer *xfer = transfer;
            __unsafe_unretained NSString *fn = filename ?: [originalURL lastPathComponent];
            __unsafe_unretained NSString *cg = chatGuid;
            BOOL hi = YES;
            BOOL ext = YES;
            [inv setArgument:&xfer atIndex:2];
            [inv setArgument:&fn atIndex:3];
            [inv setArgument:&hi atIndex:4];
            [inv setArgument:&cg atIndex:5];
            [inv setArgument:&ext atIndex:6];
            [inv retainArguments];
            [inv invoke];
            __unsafe_unretained NSString *raw = nil;
            [inv getReturnValue:&raw];
            // Take a strong reference immediately — invocation returns an
            // unretained pointer that ARC may release before the next use.
            NSString *persistentPath = raw;
            debugLog(@"prepareOutgoingTransfer: persistentPath=%@ filename=%@",
                     persistentPath ?: @"(nil)", fn);

            NSError *legacyErr = nil;
            BOOL legacyStaged = NO;
            BOOL persistentMatchesSource = NO;
            BOOL canRetargetSticker = transferKind != IMsgOutgoingTransferKindSticker
                || ([ftc respondsToSelector:@selector(retargetTransfer:toPath:)]
                    && pathIsWithinRoot(persistentPath, trustedMessagesAttachmentsRoot()));
            if (persistentPath.length && canRetargetSticker) {
                NSURL *persistentURL = [NSURL fileURLWithPath:persistentPath];
                NSURL *parent = [persistentURL URLByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtURL:parent
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:&legacyErr];
                if (!legacyErr) {
                    persistentMatchesSource =
                        pathsReferToSameFile(originalURL.path, persistentPath);
                    if (persistentMatchesSource) {
                        legacyStaged = YES;
                    } else {
                        NSURL *temporaryURL = [parent URLByAppendingPathComponent:
                            [NSString stringWithFormat:@".imsg-%@", NSUUID.UUID.UUIDString]];
                        [[NSFileManager defaultManager] copyItemAtURL:originalURL
                                                                toURL:temporaryURL
                                                                error:&legacyErr];
                        if (!legacyErr
                            && rename(temporaryURL.path.fileSystemRepresentation,
                                      persistentPath.fileSystemRepresentation) != 0) {
                            legacyErr = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                           code:errno
                                                       userInfo:nil];
                        }
                        if (legacyErr) {
                            [[NSFileManager defaultManager]
                                removeItemAtURL:temporaryURL error:NULL];
                        }
                    }
                    if (!legacyErr) {
                        BOOL retargeted = retargetPreparedTransfer(
                            ftc, transfer, transferGuid, persistentPath);
                        if (transferKind != IMsgOutgoingTransferKindSticker || retargeted) {
                            if (outActivePath) *outActivePath = persistentPath;
                            legacyStaged = YES;
                        }
                    }
                }
            }
            if (!legacyStaged) {
                // IMDPersistence on macOS 26 / Tahoe returns either nil (when
                // chatGUID is nil, per BlueBubbles' reference implementation)
                // or an iOS-style /var/mobile/... path (when chatGUID is
                // non-nil) that Messages.app can't actually write to. The
                // _alternative_ fallback that some IMDPersistence builds
                // expose, saveAttachmentsForTransfer:chatGUID:storeAtExternalLocation:completion:,
                // returns a path inside the Messages.app sandbox container
                // that imagent can't read from for outgoing sends (the row
                // lands in chat.db but error=25, is_sent=0).
                //
                // The transfer was created via guidForNewOutgoingTransferWithLocalURL:
                // with the source already living under
                // ~/Library/Messages/Attachments/imsg/<UUID>/<file> (Swift's
                // MessageSender.stageAttachmentForMessagesApp puts it there
                // before we get here). That path is in the user-visible
                // Attachments tree, which imagent reads happily — BlueBubbles
                // takes the same approach when its persistentPath comes back
                // nil. So when the legacy retarget can't run, leave the
                // transfer pointing at its original localURL and let
                // registerTransferWithDaemon: pick it up directly.
                if (legacyErr) {
                    debugLog(@"prepareOutgoingTransfer: legacy path %@ unusable (%@); "
                             @"keeping original localURL=%@ for registerTransferWithDaemon",
                             persistentPath ?: @"(nil)", legacyErr.localizedDescription,
                             originalURL.path);
                } else {
                    debugLog(@"prepareOutgoingTransfer: no persistent path; keeping "
                             @"original localURL=%@", originalURL.path);
                }
            }
        }
    }

    if (outActivePath) {
        NSString *observedPath = nil;
        if ([transfer respondsToSelector:@selector(localURL)]) {
            id value = [transfer performSelector:@selector(localURL)];
            if ([value isKindOfClass:[NSURL class]]) observedPath = [value path];
        }
        if (!observedPath.length && [transfer respondsToSelector:@selector(localPath)]) {
            id value = [transfer performSelector:@selector(localPath)];
            if ([value isKindOfClass:[NSString class]]) observedPath = value;
        }
        if (observedPath.length
            && !pathsReferToSameFile(observedPath, originalURL.path)
            && [[NSFileManager defaultManager] fileExistsAtPath:observedPath]) {
            *outActivePath = observedPath;
        }
        NSString *activePath = *outActivePath;
        if (activePath.length
            && !pathsReferToSameFile(activePath, originalURL.path)
            && [[NSFileManager defaultManager] fileExistsAtPath:activePath]
            && !removeStickerFileSecurely(originalURL.path)) {
            if (outErr) *outErr = @"Could not remove redundant sticker snapshot";
            return nil;
        }
    }

    if (transferKind == IMsgOutgoingTransferKindRichLinkPreview) {
        NSString *mimeType = transferMetadata[@"mimeType"];
        if (!configurePreviewPayloadTransfer(transfer, mimeType, filename)) {
            if (outErr) *outErr = @"Hidden preview transfer selectors unavailable";
            return nil;
        }
    }

    if (transferKind == IMsgOutgoingTransferKindSticker) {
        NSString *stickerErr = nil;
        NSString *accessibilityLabel = transferMetadata[@"accessibilityLabel"];
        if (!markTransferAsSticker(transfer, accessibilityLabel,
                                   transferMetadata, &stickerErr)) {
            if (outErr) *outErr = stickerErr ?: @"Could not mark transfer as sticker";
            return nil;
        }
    }

    return transfer;
}

static IMFileTransfer *prepareUnregisteredOutgoingTransfer(
    NSURL *originalURL, NSString *filename, NSString *chatGuid,
    BOOL hideAttachment, NSString *mimeType, NSString **outErr) {
    IMsgOutgoingTransferKind kind = hideAttachment
        ? IMsgOutgoingTransferKindRichLinkPreview
        : IMsgOutgoingTransferKindAttachment;
    NSDictionary *metadata = mimeType.length ? @{ @"mimeType": mimeType } : nil;
    return prepareOutgoingTransfer(originalURL, filename, chatGuid, kind,
                                   metadata, NULL, outErr);
}

static BOOL registerPreparedTransfer(IMFileTransfer *transfer, NSString **outErr) {
    NSString *transferGuid = [transfer guid];
    if (!transferGuid.length) {
        if (outErr) *outErr = @"Prepared transfer has no guid";
        return NO;
    }
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    id center = centerClass ? [centerClass performSelector:@selector(sharedInstance)] : nil;
    if (!center || ![center respondsToSelector:@selector(registerTransferWithDaemon:)]) {
        if (outErr) *outErr = @"registerTransferWithDaemon: unavailable";
        return NO;
    }
    [center performSelector:@selector(registerTransferWithDaemon:) withObject:transferGuid];
    return YES;
}

/// `send-attachment`: registers the file via IMFileTransferCenter and sends a
/// message whose attributedBody carries the OBJ placeholder tagged with the
/// transfer guid (Messages requires this attribute or the attachment row is
/// never linked to the outgoing message).
static NSDictionary *handleSendAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    NSString *message = params[@"message"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;
    NSNumber *audioFlag = params[@"isAudioMessage"];
    BOOL isAudio = [audioFlag boolValue];
    NSArray *textFormatting = params[@"textFormatting"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!filePath.length) return errorResponse(requestId, @"Missing filePath");
    if (!message) message = @"";
    NSError *attrErr = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:filePath error:&attrErr];
    if (!attrs) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"File not found: %@", filePath]);
    }
    if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
        return errorResponse(requestId, @"Symlinked attachment paths are not allowed");
    }
    if (pathHasSymlinkComponent(filePath)) {
        return errorResponse(requestId, @"Attachment path traverses a symlink");
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"File not found: %@", filePath]);
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSString *filename = [fileURL lastPathComponent];

    @try {
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, filename, chatGuid, IMsgOutgoingTransferKindAttachment,
            nil, NULL, &prepErr);
        if (!transfer) {
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not register attachment transfer");
        }
        NSString *transferGuid = [transfer guid];
        if (!transferGuid.length) {
            return errorResponse(requestId, @"Transfer registered without guid");
        }

        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
        NSInteger attachmentPartIndex = partIndex;
        if (message.length) {
            NSString *textPrefix = [message stringByAppendingString:@"\n"];
            NSAttributedString *textBody = nil;
            if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
                textBody = buildFormattedAttributed(textPrefix, textFormatting, partIndex);
            } else {
                textBody = buildPlainAttributed(textPrefix, partIndex);
            }
            [body appendAttributedString:textBody];
            attachmentPartIndex = partIndex + 1;
        }
        [body appendAttributedString:buildAttachmentAttributed(transferGuid, filename,
                                                               attachmentPartIndex)];

        NSAttributedString *subjectAttr = subject.length
            ? buildPlainAttributed(subject, 0)
            : nil;
        long long associatedType = selectedMessageGuid.length ? 100 : 0;
        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendAttachment: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }

        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length), nil,
                                      @[transferGuid], isAudio, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build IMMessage with attachment");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register attachment transfer");
        }
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuid": transferGuid,
            @"selectedMessageGuid": selectedMessageGuid ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-attachment failed: %@", exception.reason]);
    }
}

/// `send-sticker`: registers an outgoing file transfer and marks the transfer
/// as sticker-attributed before dispatch. A selectedMessageGuid attaches the
/// sticker to a message bubble using the same association path as tapbacks.
static void cleanupPreparedStickerPaths(NSString *snapshotPath,
                                        NSString *activePath) {
    if (activePath.length) removeStickerTransferFileSecurely(activePath);
    if (snapshotPath.length
        && ![snapshotPath.stringByStandardizingPath
            isEqualToString:activePath.stringByStandardizingPath]) {
        removeStickerFileSecurely(snapshotPath);
    }
}

static NSDictionary *handleSendSticker(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    NSString *contentHash = params[@"contentHash"];
    NSString *accessibilityLabel = params[@"accessibilityLabel"];
    NSNumber *pixelWidth = params[@"pixelWidth"];
    NSNumber *pixelHeight = params[@"pixelHeight"];
    NSString *rawSelectedMessageGuid = params[@"selectedMessageGuid"];
    NSNumber *partIndexNum = params[@"targetPartIndex"];
    if (![chatGuid isKindOfClass:[NSString class]]
        || ![filePath isKindOfClass:[NSString class]]
        || ![contentHash isKindOfClass:[NSString class]]
        || ![accessibilityLabel isKindOfClass:[NSString class]]) {
        return errorResponse(requestId,
            @"chatGuid, filePath, contentHash, and accessibilityLabel must be strings");
    }
    if (![pixelWidth isKindOfClass:[NSNumber class]]
        || ![pixelHeight isKindOfClass:[NSNumber class]]
        || CFGetTypeID((__bridge CFTypeRef)pixelWidth) == CFBooleanGetTypeID()
        || CFGetTypeID((__bridge CFTypeRef)pixelHeight) == CFBooleanGetTypeID()
        || pixelWidth.doubleValue != (double)pixelWidth.integerValue
        || pixelHeight.doubleValue != (double)pixelHeight.integerValue) {
        return errorResponse(requestId, @"pixelWidth and pixelHeight must be integers");
    }
    if (rawSelectedMessageGuid
        && ![rawSelectedMessageGuid isKindOfClass:[NSString class]]) {
        return errorResponse(requestId, @"selectedMessageGuid must be a string");
    }
    if (partIndexNum && ![partIndexNum isKindOfClass:[NSNumber class]]) {
        return errorResponse(requestId, @"targetPartIndex must be an integer");
    }
    if (partIndexNum
        && (CFGetTypeID((__bridge CFTypeRef)partIndexNum) == CFBooleanGetTypeID()
            || partIndexNum.doubleValue != (double)partIndexNum.integerValue)) {
        return errorResponse(requestId, @"targetPartIndex must be an integer");
    }
    NSInteger targetPartIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!filePath.length) return errorResponse(requestId, @"Missing filePath");
    if (targetPartIndex < 0) {
        return errorResponse(requestId, @"targetPartIndex must be non-negative");
    }
    NSString *selectedMessageGuid = rawSelectedMessageGuid;
    if ([rawSelectedMessageGuid hasPrefix:@"p:"]) {
        NSRange slash = [rawSelectedMessageGuid rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location <= 2
            || slash.location + 1 >= rawSelectedMessageGuid.length) {
            return errorResponse(requestId, @"Malformed sticker target");
        }
        NSString *embeddedPartText = [rawSelectedMessageGuid substringWithRange:
            NSMakeRange(2, slash.location - 2)];
        if ([embeddedPartText rangeOfCharacterFromSet:
                [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location
            != NSNotFound) {
            return errorResponse(requestId, @"Malformed sticker target part");
        }
        NSScanner *scanner = [NSScanner scannerWithString:embeddedPartText];
        NSInteger embeddedPart = -1;
        if (![scanner scanInteger:&embeddedPart] || !scanner.isAtEnd || embeddedPart < 0) {
            return errorResponse(requestId, @"Malformed sticker target part");
        }
        if (partIndexNum && targetPartIndex != embeddedPart) {
            return errorResponse(requestId, @"Conflicting sticker target parts");
        }
        targetPartIndex = embeddedPart;
        selectedMessageGuid = [rawSelectedMessageGuid substringFromIndex:slash.location + 1];
    }
    if ([selectedMessageGuid containsString:@"/"]) {
        return errorResponse(requestId, @"Malformed sticker target guid");
    }
    if (!selectedMessageGuid.length && targetPartIndex != 0) {
        return errorResponse(requestId, @"targetPartIndex requires selectedMessageGuid");
    }
    if (!stickerAttachmentMessageInitializerAvailable()) {
        return errorResponse(requestId,
            @"Sticker attachment message initializer unavailable");
    }
    if (selectedMessageGuid.length
        && !stickerAssociatedMessageInitializerAvailable()) {
        return errorResponse(requestId,
            @"Sticker associated-message initializer unavailable");
    }
    if (!stickerTransferSelectorsAvailable()) {
        return errorResponse(requestId, @"Required sticker transfer selectors unavailable");
    }

    NSString *metadataErr = nil;
    NSDictionary *assetMetadata = stickerAssetMetadata(filePath, &metadataErr);
    if (!assetMetadata) {
        return errorResponse(requestId,
            metadataErr.length ? metadataErr : @"Invalid sticker image");
    }
    if (![assetMetadata[@"hash"] isEqualToString:contentHash.lowercaseString]
        || ![assetMetadata[@"width"] isEqualToNumber:pixelWidth]
        || ![assetMetadata[@"height"] isEqualToNumber:pixelHeight]) {
        return errorResponse(requestId, @"Sticker metadata does not match staged bytes");
    }
    NSMutableDictionary *verifiedMetadata = [assetMetadata mutableCopy];
    verifiedMetadata[@"accessibilityLabel"] = accessibilityLabel;

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Stickers require an iMessage chat");
    }
    if (![chat respondsToSelector:@selector(sendMessage:)]) {
        return errorResponse(requestId, @"Chat send selector unavailable");
    }
    NSString *resolvedChatGuid = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : chatGuid;

    id parentChatItem = nil;
    NSRange targetRange = NSMakeRange(0, 1);
    if (selectedMessageGuid.length) {
        if (!stickerMessageBelongsToChat(chat, selectedMessageGuid)) {
            return errorResponse(requestId,
                @"Sticker target does not belong to the selected chat");
        }
        parentChatItem = findMessagePart(chat, selectedMessageGuid, targetPartIndex);
        if (!parentChatItem
            || ![parentChatItem respondsToSelector:@selector(index)]
            || [(IMMessagePartChatItem *)parentChatItem index] != targetPartIndex
            || ![parentChatItem respondsToSelector:@selector(messagePartRange)]) {
            return errorResponse(requestId, @"Sticker target message part not found");
        }
        targetRange = [(IMMessagePartChatItem *)parentChatItem messagePartRange];
        if (targetRange.length == 0) {
            return errorResponse(requestId, @"Sticker target message part has an empty range");
        }
    }

    NSString *snapshotErr = nil;
    NSString *snapshotPath = writeStickerSnapshot(assetMetadata, filePath, &snapshotErr);
    if (!snapshotPath.length) {
        return errorResponse(requestId,
            snapshotErr.length ? snapshotErr : @"Could not snapshot sticker image");
    }
    if (!removeStickerFileSecurely(filePath)) {
        removeStickerFileSecurely(snapshotPath);
        return errorResponse(requestId, @"Could not remove sticker handoff file");
    }
    [verifiedMetadata removeObjectForKey:@"data"];
    verifiedMetadata[@"filename"] = snapshotPath.lastPathComponent;
    NSURL *fileURL = [NSURL fileURLWithPath:snapshotPath];
    NSString *filename = [fileURL lastPathComponent];

    BOOL dispatchAttempted = NO;
    NSString *activePath = snapshotPath;
    @try {
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, filename, resolvedChatGuid, IMsgOutgoingTransferKindSticker,
            verifiedMetadata, &activePath, &prepErr);
        if (!transfer) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not register sticker transfer");
        }
        NSString *transferGuid = [transfer guid];
        if (!transferGuid.length) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId, @"Sticker transfer registered without guid");
        }

        // Target and outgoing attachment part indexes are different domains.
        // A sticker message contains one outgoing attachment, always part 0.
        NSAttributedString *body = buildAttachmentAttributed(transferGuid, filename, 0);
        long long associatedType = selectedMessageGuid.length ? 1000 : 0;
        NSString *associatedRef = selectedMessageGuid;
        if (selectedMessageGuid.length) {
            associatedRef = [NSString stringWithFormat:@"p:%ld/%@",
                                                        (long)targetPartIndex,
                                                        selectedMessageGuid];
        }
        NSDictionary *summaryInfo = selectedMessageGuid.length
            ? @{@"eogcd": @3, @"ust": @YES}
            : nil;
        clearThreadContextForChat(chat, nil);

        id imMessage = buildIMMessage(body, nil, nil, nil,
                                      nil,
                                      associatedRef, associatedType,
                                      targetRange, summaryInfo,
                                      @[transferGuid], NO, NO);
        if (!imMessage) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId, @"Could not build sticker IMMessage");
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register sticker transfer");
        }
        dispatchAttempted = YES;
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuid": transferGuid,
            @"selectedMessageGuid": selectedMessageGuid ?: @"",
            @"targetPartIndex": @(targetPartIndex)
        });
    } @catch (NSException *exception) {
        if (!dispatchAttempted) {
            cleanupPreparedStickerPaths(snapshotPath, activePath);
        }
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-sticker failed: %@", exception.reason]);
    }
}

/// `send-reaction`: builds a reaction IMMessage tied to the target guid.
static NSDictionary *handleSendReaction(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSString *reactionType = params[@"reactionType"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!selectedMessageGuid.length) return errorResponse(requestId, @"Missing selectedMessageGuid");
    if (!reactionType.length) return errorResponse(requestId, @"Missing reactionType");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    long long associatedType = -1;
    NSDictionary *kindMap = @{
        @"love": @2000, @"like": @2001, @"dislike": @2002,
        @"laugh": @2003, @"emphasize": @2004, @"question": @2005,
        @"remove-love": @3000, @"remove-like": @3001, @"remove-dislike": @3002,
        @"remove-laugh": @3003, @"remove-emphasize": @3004, @"remove-question": @3005,
    };
    NSNumber *typeNum = kindMap[reactionType.lowercaseString];
    if (typeNum) associatedType = [typeNum longLongValue];
    if (associatedType <= 0) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Unknown reactionType: %@", reactionType]);
    }

    // BlueBubblesHelper-verified format for tapbacks:
    // associatedMessageGUID = `p:<partIndex>/<parent-guid>`. Without the
    // prefix the receiver doesn't render the heart on the parent message.
    NSString *associatedRef = [selectedMessageGuid hasPrefix:@"p:"]
        ? selectedMessageGuid
        : [NSString stringWithFormat:@"p:%ld/%@",
                                     (long)partIndex, selectedMessageGuid];

    // Reaction body needs the verb-style summary text — `Loved "parent
    // text"` — not an empty string. imagent silently drops reactions with
    // empty body. Best-effort: load the parent and quote its text; fall
    // back to a generic phrase if we can't resolve it.
    NSString *verb = @"Loved ";
    switch (associatedType) {
        case 2000: case 3000: verb = @"Loved "; break;
        case 2001: case 3001: verb = @"Liked "; break;
        case 2002: case 3002: verb = @"Disliked "; break;
        case 2003: case 3003: verb = @"Laughed at "; break;
        case 2004: case 3004: verb = @"Emphasized "; break;
        case 2005: case 3005: verb = @"Questioned "; break;
    }
    if (associatedType >= 3000) {
        NSString *removed = @"Removed a like from ";
        switch (associatedType) {
            case 3000: removed = @"Removed a heart from "; break;
            case 3001: removed = @"Removed a like from "; break;
            case 3002: removed = @"Removed a dislike from "; break;
            case 3003: removed = @"Removed a laugh from "; break;
            case 3004: removed = @"Removed an exclamation from "; break;
            case 3005: removed = @"Removed a question mark from "; break;
        }
        verb = removed;
    }
    id parentMsg = nil;
    id parentChatItem = loadParentFirstChatItem(selectedMessageGuid, &parentMsg);
    NSString *parentText = nil;
    if (parentMsg && [parentMsg respondsToSelector:@selector(text)]) {
        id t = [parentMsg performSelector:@selector(text)];
        if ([t isKindOfClass:[NSAttributedString class]]) {
            parentText = [(NSAttributedString *)t string];
        }
    }
    // BB-verified: derive `associatedMessageRange` from the parent's first
    // chat item — `[item messagePartRange]`. Hardcoding `{0,1}` (what we did
    // before) targets the wrong part on multipart parents (e.g. tapback on
    // the second image of a photo grid). For non-text parts (attachments)
    // BB substitutes "an attachment" for the quoted text.
    NSRange targetRange = NSMakeRange(0, 1);
    if (parentChatItem
        && [parentChatItem respondsToSelector:@selector(messagePartRange)]) {
        targetRange = [(IMMessagePartChatItem *)parentChatItem messagePartRange];
        if (targetRange.length == 0) targetRange = NSMakeRange(0, 1);
    }
    NSString *quoted = parentText.length
        ? [NSString stringWithFormat:@"%@“%@”", verb, parentText]
        : [verb stringByAppendingString:@"a message"];
    NSAttributedString *body = buildPlainAttributed(quoted, partIndex);

    // BB-verified `messageSummaryInfo` shape: `amc` is an integer count
    // (always `@1` for single-target tapbacks), `ams` is the parent text
    // (the receiver's notification preview reads `<verb> "<ams>"`). Earlier
    // we were stuffing the parent guid into `amc` as a string — the
    // resulting `message_summary_info` blob was malformed and on macOS 26
    // imagent silently dropped the reaction.
    NSDictionary *summary = @{ @"amc": @1,
                               @"ams": parentText ?: @"" };
    debugLog(@"handleSendReaction: target=%@ type=%lld range={%lu,%lu} body=%@",
             associatedRef, associatedType,
             (unsigned long)targetRange.location, (unsigned long)targetRange.length,
             quoted);

    // One-shot probe: list every IMMessage class method that mentions
    // "associated" or "instant" so we can see what reaction constructors
    // macOS 26 actually exposes. This is intentionally noisy — gates itself
    // off after the first call. Also dumps IMDPersistentAttachmentController
    // methods so we can see what attachment-staging selectors are exposed.
    static dispatch_once_t probeOnce;
    dispatch_once(&probeOnce, ^{
        Class pac = NSClassFromString(@"IMDPersistentAttachmentController");
        unsigned int pn = 0;
        Method *pm = class_copyMethodList(pac, &pn);
        for (unsigned int i = 0; i < pn; i++) {
            const char *name = sel_getName(method_getName(pm[i]));
            if (strstr(name, "ersistent") || strstr(name, "ttachment")
                || strstr(name, "ransfer") || strstr(name, "ath")) {
                debugLog(@"  -[IMDPersistentAttachmentController %s]", name);
            }
        }
        if (pm) free(pm);
        Class c = NSClassFromString(@"IMMessage");
        unsigned int n = 0;
        Method *m = class_copyMethodList(object_getClass(c), &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *name = sel_getName(method_getName(m[i]));
            if (strstr(name, "ssociated") || strstr(name, "nstantMessage")
                || strstr(name, "eaction") || strstr(name, "knowledgment")) {
                debugLog(@"  +[IMMessage %s]", name);
            }
        }
        if (m) free(m);

        Class ic = NSClassFromString(@"IMMessageItem");
        n = 0;
        Method *im = class_copyMethodList(ic, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *name = sel_getName(method_getName(im[i]));
            if (strstr(name, "ssociated") || strstr(name, "ummary")
                || strstr(name, "ssociatedMessage")) {
                debugLog(@"  -[IMMessageItem %s]", name);
            }
        }
        if (im) free(im);
    });
    @try {
        id imMessage = buildIMMessage(body, nil, nil, nil,
                                      nil,
                                      associatedRef,
                                      associatedType,
                                      targetRange,
                                      summary,
                                      @[], NO, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build reaction IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        debugLog(@"handleSendReaction: dispatched");
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"selectedMessageGuid": selectedMessageGuid,
            @"reactionType": reactionType,
            @"messageGuid": guid ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-reaction failed: %@", exception.reason]);
    }
}

/// `notify-anyways`: ask Messages.app to deliver a low-priority notification
/// for a previously-suppressed message guid.
static NSDictionary *handleNotifyAnyways(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    @try {
        // BB-verified macOS 12+ path: `markChatItemAsNotifyRecipient:` is
        // the focus-bypass primitive ("Notify Anyway" UI affordance). Our
        // previous `sendMessageAcknowledgment:forChatItem:withMessageSummaryInfo:withGuid:`
        // with ack=1000 was actually a tapback ack, not a notify-anyway —
        // wrong operation entirely.
        SEL sel = @selector(markChatItemAsNotifyRecipient:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"markChatItemAsNotifyRecipient: not available");
        }
        id item = findMessageItem(chat, messageGuid);
        if (!item) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
        }
        [chat performSelector:sel withObject:item];
        return successResponse(requestId, @{
            @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"notify-anyways failed: %@", exception.reason]);
    }
}

#pragma mark - Mutate Handlers (v2)

/// `edit-message`: rewrite an existing message via the edit selector
/// appropriate for the running macOS. Preserves BB's "Compatability" typo.
static NSDictionary *handleEditMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSString *newText = params[@"editedMessage"];
    NSString *bcText = params[@"backwardsCompatibilityMessage"]
                     ?: params[@"backwardCompatibilityMessage"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");
    if (!newText.length) return errorResponse(requestId, @"Missing editedMessage");
    if (!bcText) bcText = newText;

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasEditMessageItem && !gHasEditMessage) {
        return errorResponse(requestId, @"No edit-message selector available on this macOS");
    }

    NSAttributedString *newBody = buildPlainAttributed(newText, partIndex);
    // backwardCompatabilityText: must be an NSAttributedString; passing a plain
    // NSString makes editMessageItem: silently bail (no edit, no error).
    NSAttributedString *bcBody = [[NSAttributedString alloc] initWithString:bcText];

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }

    @try {
        NSInteger localPartIndex = partIndex;
        if (gHasEditMessageItem) {
            // editMessageItem: takes the IMMessageItem, not the chat item.
            // findMessageItem returns an IMMessagePartChatItem; reach the
            // backing item via -messageItem.
            id messageItem = [item respondsToSelector:@selector(messageItem)]
                ? [item performSelector:@selector(messageItem)] : item;
            SEL sel = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id ci = messageItem;
            [inv setArgument:&ci atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSAttributedString *bcArg = bcBody;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        } else {
            // macOS 13 path
            SEL sel = @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:);
            id message = nil;
            if ([item respondsToSelector:@selector(message)]) {
                message = [item performSelector:@selector(message)];
            }
            if (!message) {
                return errorResponse(requestId,
                    [NSString stringWithFormat:@"Message object not found: %@", messageGuid]);
            }
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id msg = message;
            [inv setArgument:&msg atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSAttributedString *bcArg = bcBody;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"edit-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `unsend-message`: retract a part of a sent message via retractMessagePart:.
static NSDictionary *handleUnsendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasRetractMessagePart) {
        return errorResponse(requestId, @"retractMessagePart: not available on this macOS");
    }

    id target = findMessagePart(chat, messageGuid, partIndex);
    if (!target) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message part not found: %ld", (long)partIndex]);
    }

    @try {
        [chat performSelector:@selector(retractMessagePart:) withObject:target];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"unsend-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `delete-message`: remove a single message from the chat.
static NSDictionary *handleDeleteMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    SEL sel = @selector(deleteChatItems:);
    if (![chat respondsToSelector:sel]) {
        return errorResponse(requestId, @"deleteChatItems: not available");
    }

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }
    @try {
        [chat performSelector:sel withObject:@[item]];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"delete-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
    });
}

#pragma mark - Chat Management Handlers (v2)

static NSDictionary *handleStartTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    debugLog(@"handleStartTyping: chatGuid=%@", chatGuid);
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        debugLog(@"handleStartTyping: chat not found");
        return errorResponse(requestId, @"Chat not found");
    }
    BOOL beforeT = NO, afterT = NO;
    if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
        beforeT = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
    }
    @try { [chat setLocalUserIsTyping:YES]; }
    @catch (NSException *ex) {
        debugLog(@"handleStartTyping: exception=%@", ex.reason);
        return errorResponse(requestId, ex.reason ?: @"failed");
    }
    if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
        afterT = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
    }
    debugLog(@"handleStartTyping: setLocalUserIsTyping:YES beforeIsTyping=%d afterIsTyping=%d "
             @"chatClass=%@", beforeT, afterT, NSStringFromClass([chat class]));
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @YES});
}

static NSDictionary *handleStopTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    debugLog(@"handleStopTyping: chatGuid=%@", chatGuid);
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat setLocalUserIsTyping:NO]; }
    @catch (NSException *ex) {
        debugLog(@"handleStopTyping: exception=%@", ex.reason);
        return errorResponse(requestId, ex.reason ?: @"failed");
    }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @NO});
}

static NSDictionary *handleCheckTypingStatus(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    BOOL typing = NO;
    if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
        typing = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
    }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @(typing)});
}

static NSDictionary *handleMarkChatRead(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *handle = params[@"handle"];
    id chat = nil;
    if (chatGuid.length) chat = resolveChatByGuid(chatGuid);
    if (!chat && handle.length) chat = findChat(handle);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat performSelector:@selector(markAllMessagesAsRead)]; }
    @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid ?: @"", @"marked_as_read": @YES});
}

static NSDictionary *handleMarkChatUnread(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        // BB-verified macOS 11+ path: `markLastMessageAsUnread` is the
        // daemon-aware selector that flips read=0 in chat.db AND triggers
        // UI badge refresh. The `setUnreadCount:` we used previously only
        // mutated a local KVO counter that didn't persist.
        if ([chat respondsToSelector:@selector(markLastMessageAsUnread)]) {
            [chat performSelector:@selector(markLastMessageAsUnread)];
        } else {
            return errorResponse(requestId, @"markLastMessageAsUnread not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"marked_as_unread": @YES});
}

static NSDictionary *handleAddParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    // Match chat-create's fallback-capable iMessage handle lookup.
    id handle = vendIMHandle(hr, address, @"iMessage", YES);
    if (!handle) return errorResponse(requestId, @"Could not vend handle");

    @try {
        // macOS 26 renamed this selector; retain the older spelling as fallback.
        SEL sel = 0;
        for (NSString *name in @[@"inviteParticipants:reason:",
                                 @"inviteParticipantsToiMessageChat:reason:"]) {
            SEL cand = NSSelectorFromString(name);
            if ([chat respondsToSelector:cand]) { sel = cand; break; }
        }
        if (!sel) {
            return errorResponse(requestId, @"no participant-invite selector available on this IMChat");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[handle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"added": @YES});
}

static NSDictionary *handleRemoveParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    // Find the matching participant handle on the chat itself.
    id targetHandle = nil;
    if ([chat respondsToSelector:@selector(participants)]) {
        for (id h in [chat performSelector:@selector(participants)]) {
            if ([h respondsToSelector:@selector(ID)]
                && [[h performSelector:@selector(ID)] isEqualToString:address]) {
                targetHandle = h; break;
            }
        }
    }
    if (!targetHandle) return errorResponse(requestId, @"Participant not found on chat");

    @try {
        // macOS 26 renamed this selector; retain the older spelling as fallback.
        SEL sel = 0;
        for (NSString *name in @[@"removeParticipants:reason:",
                                 @"removeParticipantsFromiMessageChat:reason:"]) {
            SEL cand = NSSelectorFromString(name);
            if ([chat respondsToSelector:cand]) { sel = cand; break; }
        }
        if (!sel) {
            return errorResponse(requestId, @"no participant-remove selector available on this IMChat");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[targetHandle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"removed": @YES});
}

static NSDictionary *handleSetDisplayName(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *newName = params[@"newName"] ?: params[@"name"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        // BB-verified: `_setDisplayName:` (underscore-prefixed) is the
        // private mutator that posts the IDS update so other chat members
        // see the rename. The public `setDisplayName:` we used before was
        // just the KVO setter — it changed the local property without
        // propagating, so renames were sender-only.
        if ([chat respondsToSelector:@selector(_setDisplayName:)]) {
            [chat performSelector:@selector(_setDisplayName:) withObject:newName ?: @""];
        } else {
            return errorResponse(requestId, @"_setDisplayName: not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"name": newName ?: @""});
}

static NSDictionary *handleUpdateGroupPhoto(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    @try {
        // BB-verified: group-photo updates go through the file-transfer
        // pipeline, not raw bytes. Stage the photo via prepareOutgoingTransfer
        // (so it lives in IMD's attachments tree), then call
        // sendGroupPhotoUpdate: with the transfer guid. Passing nil/empty
        // file path clears the photo.
        SEL sel = @selector(sendGroupPhotoUpdate:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"sendGroupPhotoUpdate: not available");
        }
        if (filePath.length == 0) {
            [chat performSelector:sel withObject:nil];
            return successResponse(requestId,
                @{@"chatGuid": chatGuid, @"cleared": @YES, @"size": @0});
        }
        NSURL *fileURL = [NSURL fileURLWithPath:filePath];
        NSString *prepErr = nil;
        IMFileTransfer *transfer = prepareOutgoingTransfer(
            fileURL, [fileURL lastPathComponent], chatGuid,
            IMsgOutgoingTransferKindAttachment, nil, NULL, &prepErr);
        if (!transfer || ![transfer guid].length) {
            return errorResponse(requestId,
                prepErr.length ? prepErr : @"Could not prepare group-photo transfer");
        }
        NSString *registerErr = nil;
        if (!registerPreparedTransfer(transfer, &registerErr)) {
            return errorResponse(requestId,
                registerErr.length ? registerErr : @"Could not register group-photo transfer");
        }
        [chat performSelector:sel withObject:[transfer guid]];
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"cleared": @NO,
            @"transferGuid": [transfer guid]
        });
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
}

static NSDictionary *handleLeaveChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        if ([chat respondsToSelector:@selector(leaveChat)]) {
            [chat performSelector:@selector(leaveChat)];
        } else {
            return errorResponse(requestId, @"leaveChat not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"left": @YES});
}

static NSDictionary *handleDeleteChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    SEL deleteSelector = NSSelectorFromString(@"deleteChat:");
    SEL removeSelector = NSSelectorFromString(@"_chat_remove:");
    SEL selectedSelector = NULL;
    if ([reg respondsToSelector:deleteSelector]) {
        selectedSelector = deleteSelector;
    } else if ([reg respondsToSelector:removeSelector]) {
        // macOS 26 removed deleteChat:, while Messages still uses the
        // daemon-aware registry removal path exposed as _chat_remove:.
        selectedSelector = removeSelector;
    }
    if (!reg || selectedSelector == NULL) {
        return errorResponse(requestId,
            @"Chat deletion is unavailable (deleteChat: and _chat_remove: missing)");
    }
    @try {
        [reg performSelector:selectedSelector withObject:chat];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"deleted": @YES,
        @"method": NSStringFromSelector(selectedSelector)
    });
}

/// `create-chat`: vend handles for each address, ask the registry for a chat
/// instance, optionally set the display name, optionally send an initial
/// message. Returns the new chat's guid.
static NSDictionary *handleCreateChat(NSInteger requestId, NSDictionary *params) {
    NSArray *addresses = params[@"addresses"];
    NSString *initialMessage = params[@"message"];
    NSString *displayName = params[@"displayName"] ?: params[@"name"];
    NSString *requestedService = params[@"service"] ?: @"iMessage";
    NSString *preferredService = @"iMessage";
    NSString *responseService = @"iMessage";
    BOOL allowHandleFallback = YES;

    if (![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing addresses array");
    }
    if ([requestedService caseInsensitiveCompare:@"iMessage"] == NSOrderedSame) {
        preferredService = @"iMessage";
        responseService = @"iMessage";
    } else if ([requestedService caseInsensitiveCompare:@"auto"] == NSOrderedSame) {
        preferredService = @"iMessage";
        responseService = @"iMessage";
    } else if ([requestedService caseInsensitiveCompare:@"sms"] == NSOrderedSame) {
        preferredService = @"SMS";
        responseService = @"SMS";
        allowHandleFallback = NO;
    } else {
        return errorResponse(requestId, [NSString stringWithFormat:
            @"Unsupported chat-create service: %@", requestedService]);
    }

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    if (!hr) return errorResponse(requestId, @"IMHandleRegistrar unavailable");

    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *addr in addresses) {
        if (![addr isKindOfClass:[NSString class]]) continue;
        id h = vendIMHandle(hr, addr, preferredService, allowHandleFallback);
        if (h) [handles addObject:h];
    }
    if (handles.count == 0) {
        return errorResponse(requestId, @"Could not vend handles for any address");
    }

    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    id chat = nil;
    if (handles.count == 1 && [reg respondsToSelector:@selector(chatForIMHandle:)]) {
        chat = [reg performSelector:@selector(chatForIMHandle:) withObject:handles.firstObject];
    } else if ([reg respondsToSelector:@selector(chatForIMHandles:)]) {
        chat = [reg performSelector:@selector(chatForIMHandles:) withObject:handles];
    }
    if (!chat) return errorResponse(requestId, @"Registry could not produce chat");

    if (displayName.length && [chat respondsToSelector:@selector(_setDisplayName:)]) {
        @try { [chat performSelector:@selector(_setDisplayName:) withObject:displayName]; }
        @catch (__unused NSException *ex) {}
    }

    NSString *messageGuid = nil;
    if (initialMessage.length) {
        NSAttributedString *body = buildPlainAttributed(initialMessage, 0);
        @try {
            id imMessage = buildIMMessage(body, nil, nil, nil, nil,
                                          nil, 0,
                                          NSMakeRange(0, body.length),
                                          nil, @[], NO, NO);
            if (imMessage) {
                dispatchIMMessageInChat(chat, imMessage, nil, nil);
                messageGuid = lastSentMessageGuid(chat);
            }
        } @catch (__unused NSException *ex) {}
    }

    NSString *guid = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : @"";
    NSString *observedService = serviceNameForChat(chat, guid);
    if (observedService.length) responseService = observedService;
    return successResponse(requestId, @{
        @"chatGuid": guid ?: @"",
        @"service": responseService,
        @"messageGuid": messageGuid ?: @"",
        @"participants": addresses
    });
}

#pragma mark - Introspection Handlers (v2)

static NSDictionary *handleSearchMessages(NSInteger requestId, NSDictionary *params) {
    NSString *query = params[@"query"];
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return errorResponse(requestId, @"Missing query");
    }
    // Spotlight-style search across loaded chat items via IMChatHistoryController
    // is not exposed to us cleanly without private headers; return a structured
    // not-implemented response so the CLI can degrade gracefully.
    return successResponse(requestId, @{
        @"query": query,
        @"results": @[],
        @"note": @"server-side search not yet implemented; falls back to chat.db"
    });
}

static NSDictionary *handleGetAccountInfo(NSInteger requestId, NSDictionary *params) {
    Class accClass = NSClassFromString(@"IMAccountController");
    if (!accClass) return errorResponse(requestId, @"IMAccountController unavailable");
    id ctrl = [accClass performSelector:@selector(sharedInstance)];
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if ([ctrl respondsToSelector:@selector(activeIMessageAccount)]) {
        id account = [ctrl performSelector:@selector(activeIMessageAccount)];
        if (account) {
            NSArray *aliases = nil;
            if ([account respondsToSelector:@selector(vettedAliases)]) {
                aliases = [account performSelector:@selector(vettedAliases)];
            }
            id login = nil;
            if ([account respondsToSelector:@selector(loginIMHandle)]) {
                login = [account performSelector:@selector(loginIMHandle)];
            }
            NSString *loginID = nil;
            if (login && [login respondsToSelector:@selector(ID)]) {
                loginID = [login performSelector:@selector(ID)];
            }
            info[@"vetted_aliases"] = aliases ?: @[];
            info[@"login"] = loginID ?: @"";
            info[@"service"] = @"iMessage";
        }
    }
    return successResponse(requestId, info);
}

static id sharedNicknameController(void) {
    Class nnClass = NSClassFromString(@"IMNicknameController");
    SEL sharedSelector = @selector(sharedInstance);
    if (!nnClass || ![(id)nnClass respondsToSelector:sharedSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(nnClass, sharedSelector);
}

static BOOL waitForNicknameControllerLoad(id controller, NSTimeInterval timeout) {
    SEL loadedSelector = @selector(isInitialLoadComplete);
    if (![controller respondsToSelector:loadedSelector]) return YES;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!((BOOL (*)(id, SEL))objc_msgSend)(controller, loadedSelector)) {
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        NSDate *nextCheck = [NSDate dateWithTimeIntervalSinceNow:0.05];
        if ([NSThread isMainThread]) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:nextCheck];
        } else {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    return YES;
}

static NSString *nicknameSharingMutationSelectorName(Class nnClass) {
    if (!nnClass) return nil;
    NSString *selectorName =
        @"allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:";
    return [nnClass instancesRespondToSelector:NSSelectorFromString(selectorName)]
        ? selectorName
        : nil;
}

static NSDictionary *nicknameSharingSelectorStatus(void) {
    Class nnClass = NSClassFromString(@"IMNicknameController");
    BOOL hasSharedInstance = nnClass && [(id)nnClass respondsToSelector:@selector(sharedInstance)];
    BOOL hasLookup = nnClass &&
        [nnClass instancesRespondToSelector:@selector(nicknameForHandle:)];
    BOOL hasShouldOffer = nnClass &&
        [nnClass instancesRespondToSelector:@selector(shouldOfferNicknameSharingForChat:)];
    NSString *shareSelector = nicknameSharingMutationSelectorName(nnClass);
    return @{
        @"controller": @(hasSharedInstance),
        @"nickname_lookup": @(hasSharedInstance && hasLookup),
        @"should_offer": @(hasSharedInstance && hasShouldOffer),
        @"share": @(hasSharedInstance && shareSelector != nil),
        @"share_selector": shareSelector ?: [NSNull null]
    };
}

static IMAccount *activeIMessageAccount(void) {
    Class accountControllerClass = NSClassFromString(@"IMAccountController");
    id accountController = accountControllerClass &&
            [(id)accountControllerClass respondsToSelector:@selector(sharedInstance)]
        ? ((id (*)(id, SEL))objc_msgSend)(accountControllerClass, @selector(sharedInstance))
        : nil;
    if ([accountController respondsToSelector:@selector(activeIMessageAccount)]) {
        return ((id (*)(id, SEL))objc_msgSend)(accountController,
                                               @selector(activeIMessageAccount));
    }
    return nil;
}

static NSString *nicknameLoginHandleID(IMAccount *account) {
    if (![account respondsToSelector:@selector(loginIMHandle)]) return nil;
    id loginHandle = ((id (*)(id, SEL))objc_msgSend)(account, @selector(loginIMHandle));
    if (![loginHandle respondsToSelector:@selector(ID)]) return nil;
    id handleID = ((id (*)(id, SEL))objc_msgSend)(loginHandle, @selector(ID));
    return [handleID isKindOfClass:[NSString class]] && [handleID length] ? handleID : nil;
}

static NSString *nicknameSenderHandleID(IMChat *chat, NSString **source) {
    if ([chat respondsToSelector:@selector(lastAddressedHandleID)]) {
        id handleID = ((id (*)(id, SEL))objc_msgSend)(chat, @selector(lastAddressedHandleID));
        if ([handleID isKindOfClass:[NSString class]] && [handleID length]) {
            if (source) *source = @"chat.lastAddressedHandleID";
            return handleID;
        }
    }

    IMAccount *chatAccount = [chat respondsToSelector:@selector(account)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(account))
        : nil;
    NSString *chatLoginHandleID = nicknameLoginHandleID(chatAccount);
    if (chatLoginHandleID.length) {
        if (source) *source = @"chat.account.loginIMHandle";
        return chatLoginHandleID;
    }
    return nil;
}

static NSDictionary *handleGetNicknameInfo(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return errorResponse(requestId, @"Missing address");
    }

    @try {
        id controller = sharedNicknameController();
        if (!controller) return errorResponse(requestId, @"IMNicknameController unavailable");
        if (![controller respondsToSelector:@selector(nicknameForHandle:)]) {
            return errorResponse(requestId, @"nicknameForHandle: unavailable");
        }

        IMAccount *account = activeIMessageAccount();
        if (![account respondsToSelector:@selector(imHandleWithID:)]) {
            return errorResponse(requestId, @"Active iMessage account unavailable");
        }
        id handle = ((id (*)(id, SEL, id))objc_msgSend)(account,
                                                        @selector(imHandleWithID:), address);
        if (!handle) return errorResponse(requestId, @"Could not resolve iMessage handle");

        id nickname = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                                                           @selector(nicknameForHandle:), handle);
        NSMutableDictionary *info = [@{
            @"address": address,
            @"has_nickname": @(nickname != nil)
        } mutableCopy];
        if (nickname) info[@"description"] = [nickname description] ?: @"";
        return successResponse(requestId, info);
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Nickname lookup failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }
}

static NSDictionary *handleShouldOfferNicknameSharing(NSInteger requestId,
                                                       NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return errorResponse(requestId, @"Missing chatGuid");
    }
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Name & Photo sharing requires an iMessage chat");
    }

    Class nnClass = NSClassFromString(@"IMNicknameController");
    NSDictionary *capabilities = nicknameSharingSelectorStatus();
    id controller = nil;
    @try {
        controller = sharedNicknameController();
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Name & Photo controller failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }

    NSArray *participants = [chat respondsToSelector:@selector(participants)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(participants))
        : @[];
    NSString *senderSource = nil;
    NSString *senderHandleID = nicknameSenderHandleID(chat, &senderSource);
    BOOL controllerLoaded = controller != nil && waitForNicknameControllerLoad(controller, 1.0);
    BOOL canInspectOffer = [capabilities[@"should_offer"] boolValue] && controllerLoaded;
    BOOL canShare = [capabilities[@"share"] boolValue] && controller != nil;
    BOOL hasPersonalNickname = controllerLoaded
        && [controller respondsToSelector:@selector(personalNickname)]
        && ((id (*)(id, SEL))objc_msgSend)(controller, @selector(personalNickname)) != nil;
    id shouldOffer = [NSNull null];
    if (canInspectOffer) {
        @try {
            BOOL offer = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                controller, @selector(shouldOfferNicknameSharingForChat:), chat);
            shouldOffer = @(offer);
        } @catch (NSException *exception) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Name & Photo status failed: %@",
                                           exception.reason ?: @"unknown exception"]);
        }
    }

    NSString *shareSelector = nicknameSharingMutationSelectorName(nnClass);
    BOOL available = canShare && hasPersonalNickname && participants.count > 0
        && senderHandleID.length > 0;
    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"available": @(available),
        @"can_inspect_offer": @(canInspectOffer),
        @"can_share": @(canShare),
        @"personal_nickname_loaded": @(controllerLoaded),
        @"has_personal_nickname": @(hasPersonalNickname),
        @"should_offer": shouldOffer,
        @"participant_count": @(participants.count),
        @"from_handle_available": @(senderHandleID.length > 0),
        @"from_handle_source": senderSource ?: [NSNull null],
        @"share_selector": shareSelector ?: [NSNull null],
        @"force_supported": @(canShare)
    });
}

static NSDictionary *handleShareNickname(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return errorResponse(requestId, @"Missing chatGuid");
    }
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    NSString *observedService = serviceNameForChat(chat, chatGuid);
    if (![observedService isEqualToString:@"iMessage"]
        && ![observedService isEqualToString:@"iMessageLite"]) {
        return errorResponse(requestId, @"Name & Photo sharing requires an iMessage chat");
    }

    NSArray *participants = [chat respondsToSelector:@selector(participants)]
        ? ((id (*)(id, SEL))objc_msgSend)(chat, @selector(participants))
        : nil;
    if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) {
        return errorResponse(requestId, @"Chat has no participants to share with");
    }

    Class nnClass = NSClassFromString(@"IMNicknameController");
    NSString *selectorName = nicknameSharingMutationSelectorName(nnClass);
    if (!selectorName) return errorResponse(requestId, @"Name & Photo sharing unavailable");

    @try {
        id controller = sharedNicknameController();
        if (!controller) return errorResponse(requestId, @"IMNicknameController unavailable");
        SEL selector = NSSelectorFromString(selectorName);
        if (![controller respondsToSelector:selector]) {
            return errorResponse(requestId, @"Name & Photo sharing selector unavailable");
        }
        if (!waitForNicknameControllerLoad(controller, 2.0)) {
            return errorResponse(requestId,
                @"Personal Name & Photo is still loading; retry the request");
        }
        if (![controller respondsToSelector:@selector(personalNickname)]
            || ((id (*)(id, SEL))objc_msgSend)(controller,
                                               @selector(personalNickname)) == nil) {
            return errorResponse(requestId,
                @"No personal Name & Photo is configured in Messages");
        }

        BOOL forceSend = YES;
        NSString *senderSource = nil;
        NSString *senderHandleID = nicknameSenderHandleID(chat, &senderSource);
        if (senderHandleID.length == 0) {
            return errorResponse(requestId, @"Could not resolve the chat's local sending handle");
        }
        // Explicit share requests must send even when the handles are already
        // allow-listed; the private API otherwise only updates policy state.
        // IMCore forwards fromHandle: unchanged as a local NSString handle ID;
        // only the participants array contains IMHandle objects.
        ((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(
            controller, selector, participants, chat, senderHandleID, forceSend);

        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"requested": @YES,
            @"participant_count": @(participants.count),
            @"share_selector": selectorName,
            @"force_send": @(forceSend),
            @"from_handle_source": senderSource ?: [NSNull null]
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Name & Photo sharing failed: %@",
                                       exception.reason ?: @"unknown exception"]);
    }
}

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

#pragma mark - Command Router

/// Dispatch an action by name, returning a legacy-envelope NSDictionary. Used
/// by both the v1 single-file IPC path and (after key-stripping) the v2 path.
static NSDictionary* dispatchAction(NSInteger legacyId, NSString *action,
                                    NSDictionary *params) {
    if ([action isEqualToString:@"typing"]) {
        return handleTyping(legacyId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(legacyId, params);
    } else if ([action isEqualToString:@"status"] ||
               [action isEqualToString:@"bridge-status"]) {
        return handleStatus(legacyId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(legacyId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(legacyId, @{@"pong": @YES});
    }
    // v2 actions
    if ([action isEqualToString:@"send-message"]) {
        if (params[@"richLinkPreview"] || params[@"richLinkURL"]) {
            return errorResponse(legacyId, @"Use send-rich-link for URL previews");
        }
        return handleSendMessage(legacyId, params);
    }
    if ([action isEqualToString:@"send-rich-link"]) {
        if (![params[@"richLinkPreview"] isKindOfClass:[NSDictionary class]]) {
            return errorResponse(legacyId, @"Missing rich-link descriptor");
        }
        return handleSendMessage(legacyId, params);
    }
    if ([action isEqualToString:@"send-multipart"]) return handleSendMultipart(legacyId, params);
    if ([action isEqualToString:@"send-attachment"]) return handleSendAttachment(legacyId, params);
    if ([action isEqualToString:@"send-sticker"]) return handleSendSticker(legacyId, params);
    if ([action isEqualToString:@"send-poll"]) return handleSendPoll(legacyId, params);
    if ([action isEqualToString:@"send-poll-vote"]) return handleSendPollVote(legacyId, params);
    if ([action isEqualToString:@"send-poll-unvote"]) return handleSendPollUnvote(legacyId, params);
    if ([action isEqualToString:@"send-reaction"]) return handleSendReaction(legacyId, params);
    if ([action isEqualToString:@"notify-anyways"]) return handleNotifyAnyways(legacyId, params);
    if ([action isEqualToString:@"edit-message"]) return handleEditMessage(legacyId, params);
    if ([action isEqualToString:@"unsend-message"]) return handleUnsendMessage(legacyId, params);
    if ([action isEqualToString:@"delete-message"]) return handleDeleteMessage(legacyId, params);
    if ([action isEqualToString:@"start-typing"]) return handleStartTyping(legacyId, params);
    if ([action isEqualToString:@"stop-typing"]) return handleStopTyping(legacyId, params);
    if ([action isEqualToString:@"check-typing-status"]) return handleCheckTypingStatus(legacyId, params);
    if ([action isEqualToString:@"mark-chat-read"]) return handleMarkChatRead(legacyId, params);
    if ([action isEqualToString:@"mark-chat-unread"]) return handleMarkChatUnread(legacyId, params);
    if ([action isEqualToString:@"add-participant"]) return handleAddParticipant(legacyId, params);
    if ([action isEqualToString:@"remove-participant"]) return handleRemoveParticipant(legacyId, params);
    if ([action isEqualToString:@"set-display-name"]) return handleSetDisplayName(legacyId, params);
    if ([action isEqualToString:@"update-group-photo"]) return handleUpdateGroupPhoto(legacyId, params);
    if ([action isEqualToString:@"leave-chat"]) return handleLeaveChat(legacyId, params);
    if ([action isEqualToString:@"delete-chat"]) return handleDeleteChat(legacyId, params);
    if ([action isEqualToString:@"create-chat"]) return handleCreateChat(legacyId, params);
    if ([action isEqualToString:@"search-messages"]) return handleSearchMessages(legacyId, params);
    if ([action isEqualToString:@"get-account-info"]) return handleGetAccountInfo(legacyId, params);
    if ([action isEqualToString:@"get-nickname-info"]) return handleGetNicknameInfo(legacyId, params);
    if ([action isEqualToString:@"should-offer-nickname-sharing"])
        return handleShouldOfferNicknameSharing(legacyId, params);
    if ([action isEqualToString:@"share-nickname"])
        return handleShareNickname(legacyId, params);
    if ([action isEqualToString:@"check-imessage-availability"])
        return handleCheckIMessageAvailability(legacyId, params);
    if ([action isEqualToString:@"download-purged-attachment"])
        return handleDownloadPurgedAttachment(legacyId, params);
    return errorResponse(legacyId,
        [NSString stringWithFormat:@"Unknown action: %@", action]);
}

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-bridge] Processing command: %@ (id=%ld)", action, (long)requestId);
    return dispatchAction(requestId, action, params);
}

/// Process a v2 envelope: re-route to the shared dispatcher, then strip the
/// legacy envelope keys and re-wrap with the v2 shape.
static NSDictionary* processV2Envelope(NSDictionary *envelope) {
    NSString *uuid = envelope[@"id"];
    if (![uuid isKindOfClass:[NSString class]]) uuid = @"";
    NSString *action = envelope[@"action"];
    NSDictionary *params = envelope[@"params"] ?: @{};
    if (![action isKindOfClass:[NSString class]] || action.length == 0) {
        return errorResponseV2(uuid, @"Missing action");
    }

    NSLog(@"[imsg-bridge v2] action=%@ id=%@", action, uuid);

    NSDictionary *legacy = dispatchAction(0, action, params);
    if (![legacy isKindOfClass:[NSDictionary class]]) {
        return errorResponseV2(uuid, @"Internal: handler returned non-dictionary");
    }

    BOOL ok = [legacy[@"success"] boolValue];
    if (!ok) {
        NSString *errMsg = legacy[@"error"];
        return errorResponseV2(uuid, errMsg ?: @"Unknown error");
    }

    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:legacy];
    [data removeObjectForKey:@"id"];
    [data removeObjectForKey:@"success"];
    [data removeObjectForKey:@"error"];
    [data removeObjectForKey:@"timestamp"];
    return successResponseV2(uuid, data);
}

#pragma mark - File-based IPC

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData
                                                                options:0
                                                                  error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        NSDictionary *result = processCommand(command);

        if (result != nil) {
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];

            // Clear command file to signal processing is complete
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

            NSLog(@"[imsg-bridge] Processed command, wrote response");
        }
    }
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-bridge] Starting file-based IPC");
    NSLog(@"[imsg-bridge] Command file: %@", kCommandFile);
    NSLog(@"[imsg-bridge] Response file: %@", kResponseFile);

    // Create/clear IPC files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file with PID to indicate we're ready
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY, 0644);
    if (lockFd >= 0) {
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }

    // Poll command file via NSTimer on the main run loop.
    // NSTimer survives reliably in injected dylib contexts (dispatch_source timers
    // can get deallocated).
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager]
                                   attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;

    NSLog(@"[imsg-bridge] File watcher started, ready for commands");
}

#pragma mark - Inbound Event Observers

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
static void registerEventObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // IMChatItemsDidChange: fires whenever a chat's item list shifts. We
    // inspect the userInfo to spot inserted IMTypingChatItem instances and
    // emit started-typing / stopped-typing events.
    [nc addObserverForName:@"IMChatItemsDidChangeNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            id chat = note.object;
            NSString *chatGuid = nil;
            if (chat && [chat respondsToSelector:@selector(guid)]) {
                chatGuid = [chat performSelector:@selector(guid)];
            }
            NSDictionary *userInfo = note.userInfo;
            NSArray *inserted = userInfo[@"__kIMChatValueKey"]
                              ?: userInfo[@"inserted"];
            if (![inserted isKindOfClass:[NSArray class]]) return;
            for (id item in inserted) {
                NSString *cls = NSStringFromClass([item class]);
                if ([cls containsString:@"TypingChatItem"]) {
                    BOOL isCancel = NO;
                    if ([item respondsToSelector:@selector(isCancelTypingMessage)]) {
                        isCancel = ((BOOL (*)(id, SEL))objc_msgSend)(item,
                            @selector(isCancelTypingMessage));
                    }
                    appendEvent(@{
                        @"event": isCancel ? @"stopped-typing" : @"started-typing",
                        @"data": @{ @"chatGuid": chatGuid ?: @"" }
                    });
                }
            }
        }
    }];

    // Account aliases removed (e.g., user removed an iMessage email).
    [nc addObserverForName:@"__kIMAccountAliasesRemovedNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        appendEvent(@{
            @"event": @"aliases-removed",
            @"data": note.userInfo ?: @{}
        });
    }];

    NSLog(@"[imsg-bridge] Event observers registered");
}

#pragma mark - v2 Inbox Watcher

/// Process a single inbox file end-to-end: claim, read, dispatch, write outbox,
/// remove claim. The same-directory rename is the cross-process ownership
/// boundary: only one injected process can remove the finalized request name.
static void processV2InboxFile(NSString *uuid) {
    @autoreleasepool {
        NSString *inPath = [kRpcInDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];
        NSString *claimName = [NSString stringWithFormat:@"%@.processing.%d", uuid, getpid()];
        NSString *claimPath = [kRpcInDir stringByAppendingPathComponent:claimName];
        NSString *outPath = [kRpcOutDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];

        if (rename(inPath.UTF8String, claimPath.UTF8String) != 0) {
            int claimErrno = errno;
            // ENOENT is the expected race loser: another injected process
            // already claimed this request. Other failures leave the finalized
            // file in place for a later scan instead of risking duplicate work.
            if (claimErrno != ENOENT) {
                NSLog(@"[imsg-bridge v2] Could not claim %@ (errno=%d)", inPath, claimErrno);
                debugLog(@"v2 claim failed id=%@ pid=%d errno=%d",
                         uuid, getpid(), claimErrno);
            }
            return;
        }
        debugLog(@"v2 claimed id=%@ pid=%d process=%@",
                 uuid, getpid(), [[NSProcessInfo processInfo] processName]);

        NSError *err = nil;
        NSData *body = [NSData dataWithContentsOfFile:claimPath options:0 error:&err];
        if (!body || err) {
            NSLog(@"[imsg-bridge v2] Could not read %@: %@", claimPath, err);
            // Remove malformed file so we don't retry forever.
            [[NSFileManager defaultManager] removeItemAtPath:claimPath error:nil];
            return;
        }

        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:body
                                                                 options:0
                                                                   error:&err];
        NSDictionary *response;
        if (!envelope || ![envelope isKindOfClass:[NSDictionary class]]) {
            response = errorResponseV2(uuid, @"Invalid JSON in request");
        } else {
            response = processV2Envelope(envelope);
        }

        NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                               options:0
                                                                 error:&err];
        if (responseData) {
            NSString *tmp = [outPath stringByAppendingPathExtension:@"tmp"];
            [responseData writeToFile:tmp atomically:NO];
            // Atomic rename so the CLI never reads a half-written file.
            rename(tmp.UTF8String, outPath.UTF8String);
        }

        // Drop the claimed request — we're done with it. If the process dies
        // after claiming, a later inbox scan removes the orphan without
        // replaying a potentially delivered side effect.
        [[NSFileManager defaultManager] removeItemAtPath:claimPath error:nil];
    }
}

static pid_t v2ClaimOwnerPID(NSString *name) {
    NSRange marker = [name rangeOfString:@".processing." options:NSBackwardsSearch];
    if (marker.location == NSNotFound) return 0;

    NSString *pidString = [name substringFromIndex:NSMaxRange(marker)];
    NSScanner *scanner = [NSScanner scannerWithString:pidString];
    int value = 0;
    if (![scanner scanInt:&value] || !scanner.isAtEnd || value <= 0) return 0;
    return (pid_t)value;
}

/// Claimed requests are never replayed: the handler may have dispatched its
/// side effect before dying. Delete claims owned by dead processes, claims
/// left by a recycled current PID, and old claims whose PID was reused by an
/// unrelated live process.
static void cleanupOrphanedV2Claims(NSArray *entries) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in entries) {
        pid_t ownerPID = v2ClaimOwnerPID(name);
        if (ownerPID <= 0) continue;

        NSString *path = [kRpcInDir stringByAppendingPathComponent:name];
        BOOL shouldRemove = ownerPID == getpid();
        if (!shouldRemove && kill(ownerPID, 0) != 0 && errno == ESRCH) {
            shouldRemove = YES;
        }
        if (!shouldRemove) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSDate *modified = attrs[NSFileModificationDate];
            shouldRemove =
                modified && [[NSDate date] timeIntervalSinceDate:modified] > kV2ClaimMaxAge;
        }
        if (shouldRemove) {
            [fm removeItemAtPath:path error:nil];
            debugLog(@"v2 removed orphan claim=%@ owner_pid=%d",
                     name, (int)ownerPID);
        }
    }
}

static void scanV2Inbox(void) {
    @autoreleasepool {
        NSError *err = nil;
        NSArray *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:kRpcInDir error:&err];
        if (!entries) return;
        cleanupOrphanedV2Claims(entries);
        for (NSString *name in entries) {
            // Only consume finalized .json files; skip in-flight .tmp.
            if (![name hasSuffix:@".json"]) continue;
            NSString *uuid = [name stringByDeletingPathExtension];
            processV2InboxFile(uuid);
        }
    }
}

static void startV2InboxWatcher(void) {
    initFilePaths();

    // Ensure the queue dirs exist (CLI also pre-creates them, but be defensive
    // in case a v2-only run happened). Mode 0700 keeps other UIDs / sandboxed
    // peers from being able to enumerate or inject RPC requests, and the
    // symlink check refuses to operate if any path component traverses a
    // link, see pathHasSymlinkComponent for rationale.
    NSError *secureDirError = nil;
    if (!ensureSecureDirectory(kRpcDir, &secureDirError) ||
        !ensureSecureDirectory(kRpcInDir, &secureDirError) ||
        !ensureSecureDirectory(kRpcOutDir, &secureDirError)) {
        NSLog(@"[imsg-bridge v2] Refusing insecure RPC queue path: %@",
              secureDirError.localizedDescription);
        return;
    }

    NSLog(@"[imsg-bridge v2] Inbox: %@", kRpcInDir);
    NSLog(@"[imsg-bridge v2] Outbox: %@", kRpcOutDir);

    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        scanV2Inbox();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    rpcInboxTimer = timer;

    NSLog(@"[imsg-bridge v2] Inbox watcher started");
}

#pragma mark - Dylib Entry Point

// Bridge bootstrap. Intentionally NOT run from the dylib constructor: macOS 26
// tightened dyld initializer ordering for platform/system apps, so touching
// ObjC/Foundation/IMCore at constructor time can execute before libSystem has
// finished bootstrapping ("dyld initialized but libSystem has not") and abort
// Messages.app on launch. injectedInit() only schedules this delayed bootstrap;
// the lock file is written after the watchers are installed below.
static void bridgeBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
            if (![bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
                NSLog(@"[imsg-bridge] Ignoring injected process with bundle %@",
                      bundleIdentifier ?: @"(none)");
                return;
            }
            bridgeDidBootstrap = YES;
            initFilePaths();
            NSLog(@"[imsg-bridge] Dylib injected into %@",
                  [[NSProcessInfo processInfo] processName]);
            debugLog(@"bootstrap starting in process=%@ pid=%d",
                     [[NSProcessInfo processInfo] processName], getpid());

            // Connect to IMDaemon for full IMCore access
            Class daemonClass = NSClassFromString(@"IMDaemonController");
            if (daemonClass) {
                id daemon = [daemonClass performSelector:@selector(sharedInstance)];
                if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
                    [daemon performSelector:@selector(connectToDaemon)];
                    NSLog(@"[imsg-bridge] Connected to IMDaemon");
                    debugLog(@"connected to IMDaemon");
                } else {
                    NSLog(@"[imsg-bridge] IMDaemonController available but couldn't connect");
                    debugLog(@"IMDaemonController available but couldn't connect");
                }
            } else {
                NSLog(@"[imsg-bridge] IMDaemonController class not found");
                debugLog(@"IMDaemonController class not found");
            }

            NSLog(@"[imsg-bridge] Initializing after delay...");

            // Log IMCore status
            Class registryClass = NSClassFromString(@"IMChatRegistry");
            if (registryClass) {
                id registry = [registryClass performSelector:@selector(sharedInstance)];
                if ([registry respondsToSelector:@selector(allExistingChats)]) {
                    NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                    NSLog(@"[imsg-bridge] IMChatRegistry available with %lu chats",
                          (unsigned long)chats.count);
                    debugLog(@"IMChatRegistry available chats=%lu",
                             (unsigned long)chats.count);
                }
            } else {
                NSLog(@"[imsg-bridge] IMChatRegistry NOT available");
                debugLog(@"IMChatRegistry not available");
            }

            probeSelectors();
            startFileWatcher();
            startV2InboxWatcher();
            registerEventObservers();
            debugLog(@"bootstrap complete");
        }
    });
}

__attribute__((constructor))
static void injectedInit(void) {
    // Keep the constructor tiny: only enqueue onto the main queue with
    // libdispatch. Start the startup delay from that first main-queue turn so
    // bridgeBootstrap cannot become ready to run before Messages services the
    // queue for the first time.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            bridgeBootstrap();
        });
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    if (!bridgeDidBootstrap) return;

    NSLog(@"[imsg-bridge] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (rpcInboxTimer) {
        [rpcInboxTimer invalidate];
        rpcInboxTimer = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
