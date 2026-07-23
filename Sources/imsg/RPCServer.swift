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
}

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

/// RPC methods that only read state. This is the allow-list consulted by the
/// read-only gate in `handleLine`: when the server runs in read-only mode
/// (`imsg rpc --read-only`), only methods in this set are permitted — every
/// other method name, known or not, is refused. Being an allow-list (rather
/// than a block-list of mutating methods) keeps the gate fail-closed even if a
/// future mutating method is added to the dispatch switch below but not
/// registered in `kSupportedRPCMethods`.
///
/// Every method in `kSupportedRPCMethods` must appear in exactly one of
/// `kReadOnlyRPCMethods` or `kMutatingRPCMethods`; a test enforces this so any
/// newly added method is deliberately classified.
let kReadOnlyRPCMethods: Set<String> = [
  "chats.list",
  "messages.stats",
  "messages.history",
  "watch.subscribe",
  "watch.unsubscribe",
  "messages.scheduled",
  "message.send_status",
  "contacts.shouldShareContact",
  "handles.check",
]

/// RPC methods that mutate state. Not consulted by the runtime gate directly
/// (see `kReadOnlyRPCMethods`); kept for documentation and to let a test
/// assert that every advertised method is classified as exactly one of read
/// or mutating.
let kMutatingRPCMethods: Set<String> = Set(kSupportedRPCMethods)
  .subtracting(kReadOnlyRPCMethods)

final class RPCServer {
  let store: MessageStore
  let watcher: MessageWatcher
  let output: RPCOutput
  let cache: ChatCache
  let subscriptions = SubscriptionStore()
  let verbose: Bool
  /// When true, mutating methods are refused with `RPCError.readOnly`.
  let readOnly: Bool
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

  init(
    store: MessageStore,
    verbose: Bool,
    readOnly: Bool = false,
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
    contactResolver: any ContactResolving = NoOpContactResolver()
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.readOnly = readOnly
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
  }

  func run() async throws {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLine(trimmed)
    }
    await subscriptions.cancelAll()
  }

  func handleLineForTesting(_ line: String) async {
    await handleLine(line)
  }

  func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  private func handleLine(_ line: String) async {
    let request: RPCRequest
    switch RPCRequestParser.parse(line) {
    case .success(let parsed):
      request = parsed
    case .failure(let failure):
      output.sendError(id: failure.id, error: failure.error)
      return
    }
    let method = request.method
    let params = request.params
    let id = request.id

    // Allow-list, not block-list: only methods explicitly known to be
    // read-only pass through. This stays fail-closed even if a future
    // mutating method is added to the switch below but someone forgets to
    // register it in `kSupportedRPCMethods` — it is denied by omission
    // rather than silently permitted.
    if readOnly && !kReadOnlyRPCMethods.contains(method) {
      output.sendError(id: id, error: RPCError.readOnly(method))
      return
    }

    do {
      switch method {
      case "chats.list":
        try await handleChatsList(id: id, params: params)
      case "messages.stats":
        guard request.paramsAreNamed else {
          throw RPCError.invalidParams("messages.stats params must be an object")
        }
        try await handleMessagesStats(id: id, params: params)
      case "messages.history":
        try await handleMessagesHistory(id: id, params: params)
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
        guard request.paramsAreNamed else {
          throw RPCError.invalidParams("send.sticker params must be an object")
        }
        try await handleSendSticker(params: params, id: id)
      case "messages.scheduled":
        guard request.paramsAreNamed else {
          throw RPCError.invalidParams("messages.scheduled params must be an object")
        }
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
        guard request.paramsAreNamed else {
          throw RPCError.invalidParams("contacts.shouldShareContact params must be an object")
        }
        try await handleNamePhotoStatus(params: params, id: id)
      case "contacts.shareContactCard":
        guard request.paramsAreNamed else {
          throw RPCError.invalidParams("contacts.shareContactCard params must be an object")
        }
        try await handleNamePhotoShare(params: params, id: id)
      case "handles.check":
        try await handleHandlesCheck(params: params, id: id)
      default:
        output.sendError(id: id, error: RPCError.methodNotFound(method))
      }
    } catch let err as RPCError {
      output.sendError(id: id, error: err)
    } catch let err as IMsgError {
      switch err {
      case .invalidService, .invalidChatTarget:
        output.sendError(
          id: id,
          error: RPCError.invalidParams(err.errorDescription ?? "invalid params")
        )
      default:
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
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
