#pragma mark - Selector Probes

// Populated at startup by probeSelectors(). Surfaced via the `status` action so
// the CLI can report which IMCore selectors are present on the running macOS
// (edit/unsend names changed across 13/14/15).
static BOOL gHasEditMessageItemTranslation = NO; // editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText: (macOS 26)
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
    gHasEditMessageItemTranslation = [chatClass instancesRespondToSelector:
        @selector(editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:)];
    gHasEditMessageItem = [chatClass instancesRespondToSelector:
        @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasEditMessage = [chatClass instancesRespondToSelector:
        @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasRetractMessagePart = [chatClass instancesRespondToSelector:
        @selector(retractMessagePart:)];
    gHasSendMessageReason = [chatClass instancesRespondToSelector:
        @selector(sendMessage:reason:)];
    NSLog(@"[imsg-bridge] Selector probes: editItemXlate=%d editItem=%d editLegacy=%d retract=%d sendReason=%d",
          gHasEditMessageItemTranslation, gHasEditMessageItem, gHasEditMessage,
          gHasRetractMessagePart, gHasSendMessageReason);
}

// Read the local user's typing state. macOS 26 removed -[IMChat isCurrentlyTyping];
// the live getter is -[IMChat localUserIsTyping]. Probe current, fall back to the
// legacy selector, fail closed to NO. (Before this, callers read the removed
// isCurrentlyTyping via respondsToSelector and silently got NO on every call —
// so setLocalUserIsTyping: readbacks and check-typing-status always reported 0.)
static BOOL readLocalUserIsTyping(id chat) {
    if ([chat respondsToSelector:@selector(localUserIsTyping)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(localUserIsTyping));
    }
    if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
    }
    return NO;
}

// Read the account's connected state. macOS 26 IMAccount exposes -isConnected /
// -isRegistered; the legacy -loggedIn was removed. Probe current, fall back to
// legacy, fail closed to NO. (Before this, -loggedIn was read via
// respondsToSelector and always returned NO, so diagnostics logged acctLoggedIn=0
// even on a fully-registered account.)
static BOOL readAccountConnected(id account) {
    if ([account respondsToSelector:@selector(isConnected)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(account, @selector(isConnected));
    }
    if ([account respondsToSelector:@selector(loggedIn)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(account, @selector(loggedIn));
    }
    return NO;
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

static IMAccount *activeIMessageAccount(void);
static NSDictionary *handleCheckIMessageAvailability(NSInteger requestId, NSDictionary *params);

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

