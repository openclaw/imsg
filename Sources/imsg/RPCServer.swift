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
  "messages.history",
  "watch.subscribe",
  "watch.unsubscribe",
  "send",
  "send.rich",
  "send.attachment",
  "tapback",
  "typing",
  "read",
  "message.edit",
  "message.unsend",
  "message.delete",
  "message.notifyAnyways",
  "group.rename",
  "group.setIcon",
  "group.addParticipant",
  "group.removeParticipant",
  "group.leave",
  "handles.check",
]

final class RPCServer {
  let store: MessageStore
  let watcher: MessageWatcher
  let output: RPCOutput
  let cache: ChatCache
  let subscriptions = SubscriptionStore()
  let verbose: Bool
  let sendMessage: (MessageSendOptions) throws -> Void
  let resolveSentMessage: SentMessageResolver
  let bridgeInvoker: BridgeInvoker
  let stageAttachment: AttachmentStager
  let isBridgeReady: () -> Bool
  let startTyping: (String) throws -> Void
  let stopTyping: (String) throws -> Void
  let contactResolver: any ContactResolving

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
    self.output = output
    self.sendMessage = sendMessage
    self.resolveSentMessage = resolveSentMessage
    self.bridgeInvoker = invokeBridge
    self.stageAttachment = stageAttachment
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

    do {
      switch method {
      case "chats.list":
        try await handleChatsList(id: id, params: params)
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
