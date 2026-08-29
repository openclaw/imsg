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
  let sendMessage: (MessageSendOptions) throws -> Void
  let resolveSentMessage: SentMessageResolver
  let bridgeInvoker: BridgeInvoker
  let captionVerifier: CaptionVerifier
  let stageAttachment: AttachmentStager
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

  /// Confirms a caption row reached the target chat. Returns nil when the
  /// check could not run, which must never be reported as a delivery verdict.
  typealias CaptionVerifier = (
    _ captionGUID: String, _ chatGUID: String, _ store: MessageStore?
  ) async -> Bool?

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
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
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
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

  func run() async throws {
    try await run(lines: RPCLineSource.standardInput())
  }

  func run(lines: RPCLineStream) async throws {
    let scheduler = RPCScheduler(server: self)
    try await withTaskCancellationHandler {
      try await run(lines: lines, scheduler: scheduler)
    } onCancel: {
      Task.detached { [subscriptions] in
        await scheduler.stopAdmissionAndCancelReadControl()
        await subscriptions.cancelAll()
      }
    }
  }

  private func run(lines: RPCLineStream, scheduler: RPCScheduler) async throws {
    var sourceError: Error?
    do {
      for try await line in lines {
        try Task.checkCancellation()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        await scheduler.submit(trimmed)
      }
    } catch {
      sourceError = error
    }

    let cancelled = Task.isCancelled || sourceError is CancellationError
    if cancelled || sourceError != nil {
      await scheduler.stopAdmissionAndCancelReadControl()
    } else {
      await scheduler.stopAdmission()
    }
    // EOF and cancellation stop live producers before accepted request drain.
    await subscriptions.cancelAll()
    await scheduler.waitUntilDrained()
    output.flush()

    if let sourceError {
      throw sourceError
    }
    if cancelled || Task.isCancelled {
      throw CancellationError()
    }
  }

  func handleLineForTesting(_ line: String) async {
    _ = await handleLine(line)
  }

  func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  func handleLine(_ line: String) async -> RPCExecutionResult {
    let request: RPCRequest
    switch RPCRequestParser.parse(line) {
    case .success(let parsed):
      request = parsed
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
      return .completed
    }
    let method = request.method
    let params = request.params
    let id = request.id

    do {
      guard let route = rpcDispatchRoutes[method] else {
        if !request.isNotification {
          output.sendError(id: id, error: RPCError.methodNotFound(method))
        }
        return .completed
      }
      switch route {
      case .initialize:
        try await handleInitialize(id: id, params: params)
      case .status:
        try await handleStatus(id: id, params: params)
      case .chatsList:
        try await handleChatsList(id: id, params: params)
      case .messagesStats:
        try await handleMessagesStats(id: id, params: params)
      case .messagesHistory:
        try await handleMessagesHistory(id: id, params: params)
      case .messagesSearch:
        try await handleMessagesSearch(id: id, params: params)
      case .messagesAfter:
        try await handleMessagesAfter(id: id, params: params)
      case .watchSubscribe:
        try await handleWatchSubscribe(id: id, params: params)
      case .bridgeEventsSubscribe:
        try await handleBridgeEventsSubscribe(id: id, params: params)
      case .watchUnsubscribe:
        try await handleWatchUnsubscribe(id: id, params: params)
      case .send:
        try await handleSend(params: params, id: id)
      case .sendTracked:
        try await handleSendTracked(params: params, id: id)
      case .sendRich:
        try await handleSendRich(params: params, id: id)
      case .sendAttachment:
        try await handleSendAttachment(params: params, id: id)
      case .sendMultipart:
        try await handleSendMultipart(params: params, id: id)
      case .sendSticker:
        try await handleSendSticker(params: params, id: id)
      case .messagesScheduled:
        try await handleMessagesScheduled(params: params, id: id)
      case .pollSend:
        try await handlePollSend(params: params, id: id)
      case .pollVote:
        try await handlePollVote(params: params, id: id)
      case .pollUnvote:
        try await handlePollUnvote(params: params, id: id)
      case .tapback:
        try await handleTapback(params: params, id: id)
      case .typing:
        try await handleTyping(params: params, id: id)
      case .read:
        try await handleRead(params: params, id: id)
      case .messageEdit:
        try await handleMessageEdit(params: params, id: id)
      case .messageUnsend:
        try await handleMessageUnsend(params: params, id: id)
      case .messageDelete:
        try await handleMessageDelete(params: params, id: id)
      case .messageNotifyAnyways:
        try await handleMessageNotifyAnyways(params: params, id: id)
      case .messageSendStatus:
        try await handleMessageSendStatus(params: params, id: id)
      case .chatsCreate:
        try await handleChatsCreate(id: id, params: params)
      case .chatsDelete:
        try await handleChatsDelete(id: id, params: params)
      case .chatsMarkUnread:
        try await handleChatsMarkUnread(id: id, params: params)
      case .groupRename:
        try await handleGroupRename(id: id, params: params)
      case .groupSetIcon:
        try await handleGroupSetIcon(id: id, params: params)
      case .groupAddParticipant:
        try await handleGroupAddParticipant(id: id, params: params)
      case .groupRemoveParticipant:
        try await handleGroupRemoveParticipant(id: id, params: params)
      case .groupLeave:
        try await handleGroupLeave(id: id, params: params)
      case .contactsShouldShare:
        try await handleNamePhotoStatus(params: params, id: id)
      case .contactsShare:
        try await handleNamePhotoShare(params: params, id: id)
      case .handlesCheck:
        try await handleHandlesCheck(params: params, id: id)
      }
    } catch is CancellationError {
      return .completed
    } catch let signal as RPCMutationPoisonSignal {
      return .deliveryFailure(signal.failure)
    } catch let failure as DeliveryFailure {
      if !request.isNotification {
        output.sendError(id: id, error: RPCError.deliveryFailure(failure))
      }
      return .deliveryFailure(failure)
    } catch let err as RPCError {
      if !request.isNotification {
        output.sendError(id: id, error: err)
      }
    } catch let err as IMsgError {
      guard !request.isNotification else { return .completed }
      if err.isCallerCausedRPCError {
        output.sendError(id: id, error: RPCError.invalidParams(err.localizedDescription))
      } else {
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      if !request.isNotification {
        output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
      }
    }
    return .completed
  }

  func rejectBusy(_ line: String) {
    switch RPCRequestParser.parse(line) {
    case .success(let request):
      if !request.isNotification {
        output.sendError(
          id: request.id,
          error: RPCError.serverBusy("outstanding request limit exceeded")
        )
      }
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
    }
  }

  func rejectMutationBlocked(_ line: String, poison: DeliveryFailure) {
    guard case .success(let request) = RPCRequestParser.parse(line) else { return }
    if !request.isNotification {
      output.sendError(id: request.id, error: RPCError.mutationLaneBlocked(poison))
    }
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

extension IMsgError {
  fileprivate var isCallerCausedRPCError: Bool {
    switch self {
    case .invalidISODate, .invalidService, .unsupportedService, .invalidChatTarget,
      .invalidReaction, .unsupportedReaction, .chatNotFound:
      return true
    case .permissionDenied, .appleScriptFailure, .typingIndicatorFailed:
      return false
    }
  }
}
