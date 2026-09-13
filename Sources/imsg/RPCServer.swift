import Foundation
import IMsgCore

typealias SentMessageResolver = (
  _ store: MessageStore,
  _ options: MessageSendOptions,
  _ chatID: Int64?,
  _ sentAt: Date
) async throws -> Message?

typealias BridgeInvoker = (
  _ action: BridgeAction,
  _ params: [String: Any]
) async throws -> [String: Any]

typealias AttachmentStager = (_ path: String) throws -> String
typealias StickerStager = (_ path: String) throws -> PreparedStickerAsset

enum RPCExecutionResult: Sendable, Equatable {
  case completed
  case deliveryFailure(DeliveryFailure)
}

struct RPCMutationPoisonSignal: Error, Sendable {
  let failure: DeliveryFailure
}

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
  func flush()
}

typealias RPCWatchStreamProvider = (
  _ watcher: MessageWatcher,
  _ chatID: Int64?,
  _ sinceRowID: Int64?,
  _ configuration: MessageWatcherConfiguration,
  _ filter: MessageFilter
) -> AsyncThrowingStream<Message, Error>

typealias RPCBridgeEventStreamProvider = (
  _ path: String,
  _ bufferLimit: Int
) throws -> AsyncThrowingStream<IMsgEventTailer.Event, Error>

// MessageStore, stdout, and watcher state are serial-queue-owned; subscriptions are actors.
// Remaining production dependencies are immutable or internally synchronized.
final class RPCServer: @unchecked Sendable {
  let databaseResources: RPCDatabaseResourceOwner
  let output: RPCOutput
  let subscriptions: SubscriptionStore
  let verbose: Bool
  let sendMessage: (MessageSendOptions) throws -> MessageSendOptions
  let resolveSentMessage: SentMessageResolver
  let bridgeInvoker: BridgeInvoker
  let captionVerifier: CaptionVerifier
  let stageAttachment: AttachmentStager
  let stageAudioAttachment: AttachmentStager
  let stageSticker: StickerStager
  let prepareRichLink: RichLinkPrepare
  let isBridgeReady: () -> Bool
  let startTyping: (String) throws -> Void
  let stopTyping: (String) throws -> Void
  let markAsRead: (String) async throws -> Void
  let contactResolver: any ContactResolving
  let watchStreamProvider: RPCWatchStreamProvider
  let bridgeEventsPath: String
  let bridgeEventPathUsable: @Sendable (String) -> Bool
  let bridgeEventStreamProvider: RPCBridgeEventStreamProvider

  /// Reports the caption row's outcome in the target chat, including explicit
  /// unknown and unavailable states that must not become delivery verdicts.
  typealias CaptionVerifier = (
    _ captionGUID: String, _ chatGUID: String, _ store: MessageStore?
  ) async -> PollCaptionStatus.VerificationOutcome

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> MessageSendOptions = {
      try MessageSender().sendResolvingRoute($0)
    },
    resolveSentMessage: @escaping SentMessageResolver = RPCServer.resolveSentMessage,
    invokeBridge: @escaping BridgeInvoker = { action, params in
      try await IMsgBridgeClient.shared.invokeWithoutLaunching(action: action, params: params)
    },
    verifyCaption: @escaping CaptionVerifier = { captionGUID, chatGUID, store in
      await PollCaptionStatus.verifyCaption(
        captionGUID: captionGUID, chatGUID: chatGUID, store: store,
        timeout: PollCaptionStatus.rpcVerifyTimeout)
    },
    stageAttachment: @escaping AttachmentStager = MessageSender.stageAttachmentForMessagesApp,
    stageAudioAttachment: @escaping AttachmentStager = AudioMessagePreparer.prepare,
    stageSticker: @escaping StickerStager = {
      try StickerAssetPreparer.prepare(at: $0)
    },
    prepareRichLink: @escaping RichLinkPrepare = { rawURL in
      try await RichLinkPreparer.prepare(rawURL)
    },
    isBridgeReady: @escaping () -> Bool = { true },
    startTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.startTyping(chatIdentifier: $0)
    },
    stopTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.stopTyping(chatIdentifier: $0)
    },
    markAsRead: @escaping (String) async throws -> Void = {
      try await IMCoreBridge.shared.markAsRead(handle: $0)
    },
    contactResolver: any ContactResolving = NoOpContactResolver(),
    bridgeEventsPath: String = MessagesLauncher.shared.bridgeEventsFile,
    bridgeEventPathUsable: @escaping @Sendable (String) -> Bool = rpcBridgeEventPathUsable,
    bridgeEventStreamProvider: @escaping RPCBridgeEventStreamProvider = { path, bufferLimit in
      try IMsgEventTailer(path: path, bufferLimit: bufferLimit).events()
    },
    watchStreamProvider: @escaping RPCWatchStreamProvider = {
      watcher, chatID, sinceRowID, configuration, filter in
      watcher.stream(
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        filter: filter
      )
    }
  ) {
    self.databaseResources = RPCDatabaseResourceOwner(store: store)
    self.subscriptions = SubscriptionStore(limit: 64)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    self.resolveSentMessage = resolveSentMessage
    self.bridgeInvoker = invokeBridge
    self.captionVerifier = verifyCaption
    self.stageAttachment = stageAttachment
    self.stageAudioAttachment = stageAudioAttachment
    self.stageSticker = stageSticker
    self.prepareRichLink = prepareRichLink
    self.isBridgeReady = isBridgeReady
    self.startTyping = startTyping
    self.stopTyping = stopTyping
    self.markAsRead = markAsRead
    self.contactResolver = contactResolver
    self.bridgeEventsPath = bridgeEventsPath
    self.bridgeEventPathUsable = bridgeEventPathUsable
    self.bridgeEventStreamProvider = bridgeEventStreamProvider
    self.watchStreamProvider = watchStreamProvider
  }

  init(
    databasePath: String,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    storeFactory: @escaping RPCMessageStoreFactory = { try MessageStore(path: $0) },
    sendMessage: @escaping (MessageSendOptions) throws -> MessageSendOptions = {
      try MessageSender().sendResolvingRoute($0)
    },
    resolveSentMessage: @escaping SentMessageResolver = RPCServer.resolveSentMessage,
    invokeBridge: @escaping BridgeInvoker = { action, params in
      try await IMsgBridgeClient.shared.invokeWithoutLaunching(action: action, params: params)
    },
    verifyCaption: @escaping CaptionVerifier = { captionGUID, chatGUID, store in
      await PollCaptionStatus.verifyCaption(
        captionGUID: captionGUID, chatGUID: chatGUID, store: store,
        timeout: PollCaptionStatus.rpcVerifyTimeout)
    },
    stageAttachment: @escaping AttachmentStager = MessageSender.stageAttachmentForMessagesApp,
    stageAudioAttachment: @escaping AttachmentStager = AudioMessagePreparer.prepare,
    stageSticker: @escaping StickerStager = { try StickerAssetPreparer.prepare(at: $0) },
    prepareRichLink: @escaping RichLinkPrepare = { try await RichLinkPreparer.prepare($0) },
    isBridgeReady: @escaping () -> Bool = { IMsgBridgeClient.shared.isReady() },
    startTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.startTyping(chatIdentifier: $0)
    },
    stopTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.stopTyping(chatIdentifier: $0)
    },
    markAsRead: @escaping (String) async throws -> Void = {
      try await IMCoreBridge.shared.markAsRead(handle: $0)
    },
    contactResolver: any ContactResolving = NoOpContactResolver(),
    bridgeEventsPath: String = MessagesLauncher.shared.bridgeEventsFile,
    bridgeEventPathUsable: @escaping @Sendable (String) -> Bool = rpcBridgeEventPathUsable,
    bridgeEventStreamProvider: @escaping RPCBridgeEventStreamProvider = { path, bufferLimit in
      try IMsgEventTailer(path: path, bufferLimit: bufferLimit).events()
    },
    watchStreamProvider: @escaping RPCWatchStreamProvider = {
      watcher, chatID, sinceRowID, configuration, filter in
      watcher.stream(
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        filter: filter
      )
    }
  ) {
    self.databaseResources = RPCDatabaseResourceOwner(path: databasePath, factory: storeFactory)
    self.subscriptions = SubscriptionStore(limit: 64)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    self.resolveSentMessage = resolveSentMessage
    self.bridgeInvoker = invokeBridge
    self.captionVerifier = verifyCaption
    self.stageAttachment = stageAttachment
    self.stageAudioAttachment = stageAudioAttachment
    self.stageSticker = stageSticker
    self.prepareRichLink = prepareRichLink
    self.isBridgeReady = isBridgeReady
    self.startTyping = startTyping
    self.stopTyping = stopTyping
    self.markAsRead = markAsRead
    self.contactResolver = contactResolver
    self.bridgeEventsPath = bridgeEventsPath
    self.bridgeEventPathUsable = bridgeEventPathUsable
    self.bridgeEventStreamProvider = bridgeEventStreamProvider
    self.watchStreamProvider = watchStreamProvider
  }

  func handleLineForTesting(_ line: String) async {
    _ = await handleLine(line)
  }

  func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  static func resolveSentMessage(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    sentAt: Date
  ) async throws -> Message? {
    try await SentMessageVerifier.resolveSentMessage(
      store: store,
      options: options,
      chatID: chatID,
      sentAt: sentAt
    )
  }
}
