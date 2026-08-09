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

/// Methods exposed by `imsg rpc` over JSON-RPC. Advertised to clients via
/// `imsg status --json` (`rpc_methods` field) so capability-aware consumers can
/// inspect the exact surface exposed by the installed binary.
///
/// Keep in sync with the dispatch switch in `RPCServer.handleLine`.
let kSupportedRPCMethods: [String] = [
  "chats.list",
  "chats.create",
  "chats.delete",
  "chats.markUnread",
  "messages.stats",
  "messages.history",
  "messages.after",
  "watch.subscribe",
  "watch.unsubscribe",
  "send",
  "send.rich",
  "send.attachment",
  "send.sticker",
  "messages.scheduled",
  "poll.send",
  "messages.poll.send",
  "poll.vote",
  "messages.poll.vote",
  "poll.unvote",
  "polls.unvote",
  "messages.poll.unvote",
  "tapback",
  "typing",
  "read",
  "message.edit",
  "message.unsend",
  "message.delete",
  "message.notifyAnyways",
  "message.send_status",
  "group.rename",
  "group.setIcon",
  "group.addParticipant",
  "group.removeParticipant",
  "group.leave",
  "contacts.shouldShareContact",
  "contacts.shareContactCard",
  "handles.check",
]

// MessageStore, stdout, and watcher state are serial-queue-owned; caches and subscriptions are
// actors. Remaining production dependencies are immutable or internally synchronized.
final class RPCServer: @unchecked Sendable {
  let store: MessageStore
  let watcher: MessageWatcher
  let output: RPCOutput
  let cache: ChatCache
  let subscriptions: SubscriptionStore
  let verbose: Bool
  let sendMessage: (MessageSendOptions) throws -> Void
  let resolveSentMessage: SentMessageResolver
  let bridgeInvoker: BridgeInvoker
  let stageAttachment: AttachmentStager
  let stageSticker: StickerStager
  let prepareRichLink: RichLinkPrepare
  let isBridgeReady: () -> Bool
  let startTyping: (String) throws -> Void
  let stopTyping: (String) throws -> Void
  let contactResolver: any ContactResolving
  let watchStreamProvider: RPCWatchStreamProvider

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    resolveSentMessage: @escaping SentMessageResolver = RPCServer.resolveSentMessage,
    invokeBridge: @escaping BridgeInvoker = { action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    },
    stageAttachment: @escaping AttachmentStager = MessageSender.stageAttachmentForMessagesApp,
    stageSticker: @escaping StickerStager = {
      try StickerAssetPreparer.prepare(at: $0)
    },
    prepareRichLink: @escaping RichLinkPrepare = { rawURL in
      try await RichLinkPreparer.prepare(rawURL)
    },
    isBridgeReady: @escaping () -> Bool = { IMsgBridgeClient.shared.isReady() },
    startTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.startTyping(chatIdentifier: $0)
    },
    stopTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.stopTyping(chatIdentifier: $0)
    },
    contactResolver: any ContactResolving = NoOpContactResolver(),
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
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.subscriptions = SubscriptionStore(limit: 64)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    self.resolveSentMessage = resolveSentMessage
    self.bridgeInvoker = invokeBridge
    self.stageAttachment = stageAttachment
    self.stageSticker = stageSticker
    self.prepareRichLink = prepareRichLink
    self.isBridgeReady = isBridgeReady
    self.startTyping = startTyping
    self.stopTyping = stopTyping
    self.contactResolver = contactResolver
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
    await handleLine(line)
  }

  func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  func handleLine(_ line: String) async {
    let request: RPCRequest
    switch RPCRequestParser.parse(line) {
    case .success(let parsed):
      request = parsed
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
      return
    }
    let method = request.method
    let params = request.params
    let id = request.id

    do {
      switch method {
      case "chats.list":
        try await handleChatsList(id: id, params: params)
      case "messages.stats":
        try await handleMessagesStats(id: id, params: params)
      case "messages.history":
        try await handleMessagesHistory(id: id, params: params)
      case "messages.after":
        try await handleMessagesAfter(id: id, params: params)
      case "watch.subscribe":
        try await handleWatchSubscribe(id: id, params: params)
      case "watch.unsubscribe":
        try await handleWatchUnsubscribe(id: id, params: params)
      case "send":
        try await handleSend(params: params, id: id)
      case "send.rich":
        try await handleSendRich(params: params, id: id)
      case "send.attachment":
        try await handleSendAttachment(params: params, id: id)
      case "send.sticker":
        try await handleSendSticker(params: params, id: id)
      case "messages.scheduled":
        try await handleMessagesScheduled(params: params, id: id)
      case "poll.send", "messages.poll.send":
        try await handlePollSend(params: params, id: id)
      case "poll.vote", "messages.poll.vote":
        try await handlePollVote(params: params, id: id)
      case "poll.unvote", "polls.unvote", "messages.poll.unvote":
        try await handlePollUnvote(params: params, id: id)
      case "tapback":
        try await handleTapback(params: params, id: id)
      case "typing":
        try await handleTyping(params: params, id: id)
      case "read":
        try await handleRead(params: params, id: id)
      case "message.edit":
        try await handleMessageEdit(params: params, id: id)
      case "message.unsend":
        try await handleMessageUnsend(params: params, id: id)
      case "message.delete":
        try await handleMessageDelete(params: params, id: id)
      case "message.notifyAnyways":
        try await handleMessageNotifyAnyways(params: params, id: id)
      case "message.send_status":
        try await handleMessageSendStatus(params: params, id: id)
      case "chats.create":
        try await handleChatsCreate(id: id, params: params)
      case "chats.delete":
        try await handleChatsDelete(id: id, params: params)
      case "chats.markUnread":
        try await handleChatsMarkUnread(id: id, params: params)
      case "group.rename":
        try await handleGroupRename(id: id, params: params)
      case "group.setIcon":
        try await handleGroupSetIcon(id: id, params: params)
      case "group.addParticipant":
        try await handleGroupAddParticipant(id: id, params: params)
      case "group.removeParticipant":
        try await handleGroupRemoveParticipant(id: id, params: params)
      case "group.leave":
        try await handleGroupLeave(id: id, params: params)
      case "contacts.shouldShareContact":
        try await handleNamePhotoStatus(params: params, id: id)
      case "contacts.shareContactCard":
        try await handleNamePhotoShare(params: params, id: id)
      case "handles.check":
        try await handleHandlesCheck(params: params, id: id)
      default:
        if !request.isNotification {
          output.sendError(id: id, error: RPCError.methodNotFound(method))
        }
      }
    } catch is CancellationError {
      return
    } catch let err as RPCError {
      if !request.isNotification {
        output.sendError(id: id, error: err)
      }
    } catch let err as IMsgError {
      guard !request.isNotification else { return }
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
