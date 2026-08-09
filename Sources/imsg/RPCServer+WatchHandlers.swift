import Foundation
import IMsgCore

extension RPCServer {
  func handleWatchSubscribe(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "watch.subscribe",
      supportedKeys: [
        "chat_id", "since_rowid", "participants", "start", "end", "attachments",
        "convert_attachments", "include_reactions", "debounce_ms", "debounceMs",
        "buffer_limit", "bufferLimit",
      ]
    )
    let chatID = try params.int64("chat_id")
    if let chatID, chatID <= 0 {
      throw RPCError.invalidParams("chat_id must be a positive integer")
    }
    let sinceRowID = try params.int64("since_rowid")
    let participants = try params.stringArray("participants") ?? []
    let startISO = try params.string("start")
    let endISO = try params.string("end")
    let includeAttachments = try params.boolean("attachments") ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: try params.boolean("convert_attachments") ?? false)
    let includeReactions = try params.boolean("include_reactions") ?? false
    let debounceInterval = try watchDebounceIntervalParam(params)
    let bufferLimit = try params.integer("buffer_limit", aliases: ["bufferLimit"]) ?? 256
    guard (1...4096).contains(bufferLimit) else {
      throw RPCError.invalidParams("buffer_limit must be an integer between 1 and 4096")
    }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      bufferLimit: bufferLimit,
      includeReactions: includeReactions
    )
    let reservation: SubscriptionStore.Reservation
    switch await subscriptions.reserve() {
    case .reserved(let value):
      reservation = value
    case .closed:
      throw RPCError.serverBusy("server is shutting down")
    case .limitReached:
      throw RPCError.serverBusy("subscription limit exceeded")
    }
    let subID = reservation.id
    let localStore = store
    let localWatcher = watcher
    let localCache = cache
    let localWriter = output
    let localFilter = filter
    let localChatID = chatID
    let localSinceRowID = sinceRowID
    let localConfig = config
    let localIncludeAttachments = includeAttachments
    let localAttachmentOptions = attachmentOptions
    let localIncludeReactions = includeReactions
    let localContactResolver = contactResolver
    let localSubscriptions = subscriptions
    let localStreamProvider = watchStreamProvider
    let startGate = SubscriptionStartGate()
    let task = Task {
      let activated = await startGate.wait()
      guard activated, !Task.isCancelled else {
        await localSubscriptions.complete(reservation)
        return
      }
      do {
        for try await message in localStreamProvider(
          localWatcher,
          localChatID,
          localSinceRowID,
          localConfig,
          localFilter
        ) {
          try Task.checkCancellation()
          let payload = try await buildMessagePayload(
            store: localStore,
            cache: localCache,
            message: message,
            includeAttachments: localIncludeAttachments,
            includeReactions: localIncludeReactions,
            attachmentOptions: localAttachmentOptions,
            contactResolver: localContactResolver
          )
          localWriter.sendNotification(
            method: "message",
            params: ["subscription": subID, "message": payload]
          )
        }
      } catch is CancellationError {
        // Subscription cancellation is an expected terminal state, not a protocol error.
      } catch let overflow as MessageWatcherOverflowError {
        localWriter.sendNotification(
          method: "watch.overflow",
          params: [
            "subscription": subID,
            "resume_after_rowid": overflow.resumeAfterRowID,
            "reason": "buffer_limit_exceeded",
            "terminal": true,
          ]
        )
      } catch {
        if !Task.isCancelled {
          localWriter.sendNotification(
            method: "error",
            params: [
              "subscription": subID,
              "error": ["message": String(describing: error)],
            ]
          )
        }
      }
      await localSubscriptions.complete(reservation)
    }
    switch await subscriptions.activate(task, reservation: reservation) {
    case .activated:
      // The task cannot pass its gate until stdout owns the complete subscribe response.
      respond(
        id: id,
        result: ["subscription": subID, "buffer_limit": bufferLimit]
      )
      await startGate.open(true)
    case .closed:
      await startGate.open(false)
      task.cancel()
      await task.value
      throw RPCError.serverBusy("server is shutting down")
    case .removed:
      await startGate.open(false)
      task.cancel()
      await task.value
      throw RPCError.serverBusy("subscription was cancelled before activation")
    }
  }

  func handleWatchUnsubscribe(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params, method: "watch.unsubscribe", supportedKeys: ["subscription"])
    guard let subID = try params.integer("subscription") else {
      throw RPCError.invalidParams("subscription is required")
    }
    guard subID > 0 else {
      throw RPCError.invalidParams("subscription must be a positive integer")
    }
    if let task = await subscriptions.removeForCancellation(subID) {
      task.cancel()
      await task.value
    }
    // Awaiting the task makes this response the final output for the subscription.
    respond(id: id, result: ["ok": true])
  }
}
