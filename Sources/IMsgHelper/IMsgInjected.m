// Injected Messages.app helper. Requires SIP disabled; see docs/advanced-imcore.md.

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
#import <sys/file.h>
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

// Feature fragments share this translation unit to preserve private linkage.
#include "BridgeState.inc"
#include "IMCoreDeclarations.inc"
#include "ChatResolution.inc"
#include "ReadStatusHandlers.inc"
#include "MessageBody.inc"
#include "MessageConstruction.inc"
#include "ThreadContext.inc"
#include "PollPayload.inc"
#include "BalloonMessage.inc"
#include "RichLinkPayload.inc"
#include "MessageBuilder.inc"
#include "MessageLookup.inc"
#include "EventLog.inc"
#include "RichLinkSnapshot.inc"
#include "SendMessage.inc"
#include "PollHandlers.inc"
#include "Multipart.inc"
#include "StickerAssets.inc"
#include "AttachmentTransfers.inc"
#include "AttachmentHandlers.inc"
#include "ReactionHandlers.inc"
#include "MessageMutation.inc"
#include "ChatHandlers.inc"
#include "AccountHandlers.inc"
#include "HandleHandlers.inc"
#include "Routing.inc"
#include "LegacyIPC.inc"
#include "EventObservers.inc"
#include "Inbox.inc"
#include "Ownership.inc"
#include "Bootstrap.inc"
