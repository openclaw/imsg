import Foundation
import IMsgCore

#if os(macOS)
  import Darwin
#endif

func rpcBridgeEventPathUsable(_ path: String) -> Bool {
  #if os(macOS)
    var info = stat()
    return lstat(path, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG
      && access(path, R_OK) == 0
  #else
    return false
  #endif
}

func bridgeEventPayload(_ event: IMsgEventTailer.Event) -> [String: Any] {
  var payload: [String: Any] = [
    "event": event.name,
    "data": event.decodedPayload(),
  ]
  if let timestamp = event.timestamp { payload["ts"] = timestamp }
  return payload
}

extension RPCServer {
  func handleBridgeEventsSubscribe(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "bridge.events.subscribe",
      supportedKeys: ["buffer_limit"]
    )
    let bufferLimit = try params.integer("buffer_limit") ?? 256
    guard (1...4096).contains(bufferLimit) else {
      throw RPCError.invalidParams("buffer_limit must be an integer between 1 and 4096")
    }

    let bridge = try await bridgeSnapshot()
    guard bridge.supports(.eventStream) else {
      let detail =
        bridge.error ?? "The existing v2 bridge event log is not a readable regular file."
      throw RPCError.bridgeEventsUnavailable(detail: detail)
    }

    let reservation: SubscriptionStore.Reservation
    switch await subscriptions.reserve() {
    case .reserved(let value):
      reservation = value
    case .closed:
      throw RPCError.serverBusy("server is shutting down")
    case .limitReached:
      throw RPCError.serverBusy("subscription limit exceeded")
    }

    let subscriptionID = reservation.id
    let localSubscriptions = subscriptions
    let localWriter = output
    let localPath = bridgeEventsPath
    let localStreamProvider = bridgeEventStreamProvider
    let startGate = SubscriptionStartGate()
    let task = Task {
      let activated = await startGate.wait()
      guard activated, !Task.isCancelled else {
        await localSubscriptions.complete(reservation)
        return
      }
      do {
        let stream = try localStreamProvider(localPath, bufferLimit)
        for try await event in stream {
          try Task.checkCancellation()
          localWriter.sendNotification(
            method: "bridge.event",
            params: [
              "subscription": subscriptionID,
              "event": bridgeEventPayload(event),
            ]
          )
        }
      } catch is CancellationError {
        // Explicit unsubscribe and process EOF are silent terminal states.
      } catch is IMsgEventTailerOverflowError {
        localWriter.sendNotification(
          method: "bridge.events.overflow",
          params: [
            "subscription": subscriptionID,
            "reason": "buffer_limit_exceeded",
            "resumable": false,
            "terminal": true,
          ]
        )
      } catch {
        if !Task.isCancelled {
          localWriter.sendNotification(
            method: "bridge.events.error",
            params: [
              "subscription": subscriptionID,
              "error": bridgeEventTerminalError(error),
              "terminal": true,
            ]
          )
        }
      }
      await localSubscriptions.complete(reservation)
    }

    switch await subscriptions.activate(task, reservation: reservation) {
    case .activated:
      respond(
        id: id,
        result: [
          "subscription": subscriptionID,
          "buffer_limit": bufferLimit,
          "resumable": false,
        ]
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
}

private func bridgeEventTerminalError(_ error: Error) -> [String: Any] {
  let code: String
  switch error {
  case IMsgEventTailerError.createFailed:
    code = "event_log_create_failed"
  case IMsgEventTailerError.openFailed:
    code = "event_log_open_failed"
  case IMsgEventTailerError.readFailed:
    code = "event_log_read_failed"
  case IMsgEventTailerError.unsupportedPlatform:
    code = "unsupported_platform"
  case IMsgEventTailerError.invalidBufferLimit:
    code = "invalid_buffer_limit"
  case IMsgEventTailerError.alreadyStarted:
    code = "event_stream_already_started"
  default:
    code = "event_stream_failed"
  }
  return ["code": code, "message": error.localizedDescription]
}
