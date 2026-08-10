import Foundation
import IMsgCore

final class RPCWriter: RPCOutput, Sendable {
  func sendResponse(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    send(payload)
  }

  func sendNotification(method: String, params: Any) {
    send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  func flush() {
    StdoutWriter.flush()
  }

  private func send(_ object: Any) {
    do {
      let data = try JSONSerialization.data(withJSONObject: object, options: [])
      if let output = String(data: data, encoding: .utf8) {
        StdoutWriter.writeLine(output)
      }
    } catch {
      StdoutWriter.writeLine(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}"
      )
    }
  }
}

struct RPCError: Error, @unchecked Sendable {
  let code: Int
  let message: String
  let data: String?
  let structuredData: [String: Any]?

  init(code: Int, message: String, data: String?) {
    self.code = code
    self.message = message
    self.data = data
    self.structuredData = nil
  }

  private init(code: Int, message: String, structuredData: [String: Any]) {
    self.code = code
    self.message = message
    self.data = nil
    self.structuredData = structuredData
  }

  static func parseError(_ message: String) -> RPCError {
    RPCError(code: -32700, message: "Parse error", data: message)
  }

  static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: -32600, message: "Invalid Request", data: message)
  }

  static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: -32601, message: "Method not found", data: method)
  }

  static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: -32602, message: "Invalid params", data: message)
  }

  static func internalError(_ message: String) -> RPCError {
    RPCError(code: -32603, message: "Internal error", data: message)
  }

  static func serverBusy(_ message: String) -> RPCError {
    RPCError(code: -32000, message: "Server busy", data: message)
  }

  static func databaseUnavailable(path: String, detail: String) -> RPCError {
    RPCError(
      code: -32002,
      message: "Database unavailable",
      structuredData: ["path": path, "detail": detail, "retryable": true]
    )
  }

  static func bridgeUnavailable() -> RPCError {
    RPCError(
      code: -32003,
      message: "Bridge unavailable",
      structuredData: [
        "detail":
          "The bridge is not started. Run imsg launch explicitly before using bridge methods.",
        "retryable": true,
      ]
    )
  }

  static func deliveryFailure(_ failure: DeliveryFailure) -> RPCError {
    let unknown = failure.disposition != .notStarted
    return RPCError(
      code: unknown ? -32001 : -32603,
      message: unknown ? "Delivery outcome unknown" : "Delivery failed before dispatch",
      structuredData: deliveryData(failure)
    )
  }

  static func mutationLaneBlocked(_ failure: DeliveryFailure) -> RPCError {
    var data = deliveryData(failure)
    data["detail"] =
      "A prior \(failure.operation) remains in flight. Restart the RPC child before sending another mutation."
    return RPCError(code: -32004, message: "Mutation lane blocked", structuredData: data)
  }

  private static func deliveryData(_ failure: DeliveryFailure) -> [String: Any] {
    [
      "retry_safe": failure.retrySafe,
      "disposition": failure.disposition.rawValue,
      "transport": failure.transport.rawValue,
      "operation": failure.operation,
      "detail": failure.detail,
    ]
  }

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let structuredData {
      dict["data"] = structuredData
    } else if let data {
      dict["data"] = data
    }
    return dict
  }
}

actor SubscriptionStore {
  struct Reservation: Sendable, Equatable {
    let id: Int
    fileprivate let generation: UInt64
  }

  enum ReservationResult: Sendable, Equatable {
    case reserved(Reservation)
    case closed
    case limitReached
  }

  enum ActivationResult: Sendable, Equatable {
    case activated
    case closed
    case removed
  }

  private enum Entry {
    case pending(generation: UInt64)
    case active(generation: UInt64, task: Task<Void, Never>)
  }

  private let limit: Int
  private var nextID = 1
  private var nextGeneration: UInt64 = 1
  private var entries: [Int: Entry] = [:]
  private var accepting = true
  private var emptyWaiters: [CheckedContinuation<Void, Never>] = []
  private var closedWaiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = limit
  }

  func reserve() -> ReservationResult {
    guard accepting else { return .closed }
    guard entries.count < limit else { return .limitReached }
    let id = nextID
    nextID += 1
    let generation = nextGeneration
    nextGeneration += 1
    let reservation = Reservation(id: id, generation: generation)
    entries[id] = .pending(generation: generation)
    return .reserved(reservation)
  }

  func activate(_ task: Task<Void, Never>, reservation: Reservation) -> ActivationResult {
    guard accepting else { return .closed }
    guard
      case .pending(let generation) = entries[reservation.id],
      generation == reservation.generation
    else {
      return .removed
    }
    entries[reservation.id] = .active(generation: generation, task: task)
    return .activated
  }

  func removeForCancellation(_ id: Int) -> Task<Void, Never>? {
    guard let entry = entries.removeValue(forKey: id) else { return nil }
    resumeEmptyWaitersIfNeeded()
    if case .active(_, let task) = entry {
      return task
    }
    return nil
  }

  func complete(_ reservation: Reservation) {
    guard let entry = entries[reservation.id] else { return }
    let generation: UInt64
    switch entry {
    case .pending(let value), .active(let value, _):
      generation = value
    }
    if generation == reservation.generation {
      entries.removeValue(forKey: reservation.id)
      resumeEmptyWaitersIfNeeded()
    }
  }

  func cancelAll() async {
    accepting = false
    resumeClosedWaiters()
    let tasks = entries.values.compactMap { entry -> Task<Void, Never>? in
      guard case .active(_, let task) = entry else { return nil }
      return task
    }
    entries.removeAll()
    resumeEmptyWaitersIfNeeded()
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      await task.value
    }
  }

  var count: Int {
    entries.count
  }

  var nextIDForTesting: Int {
    nextID
  }

  func waitUntilEmpty() async {
    guard !entries.isEmpty else { return }
    await withCheckedContinuation { continuation in
      emptyWaiters.append(continuation)
    }
  }

  func waitUntilClosed() async {
    guard accepting else { return }
    await withCheckedContinuation { continuation in
      closedWaiters.append(continuation)
    }
  }

  private func resumeEmptyWaitersIfNeeded() {
    guard entries.isEmpty else { return }
    let waiters = emptyWaiters
    emptyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func resumeClosedWaiters() {
    let waiters = closedWaiters
    closedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

actor SubscriptionStartGate {
  private var result: Bool?
  private var waiters: [CheckedContinuation<Bool, Never>] = []

  func wait() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open(_ result: Bool) {
    guard self.result == nil else { return }
    self.result = result
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume(returning: result)
    }
  }
}

actor ChatCache {
  private let store: MessageStore
  private var infoCache: [Int64: ChatInfo] = [:]
  private var participantsCache: [Int64: [String]] = [:]

  init(store: MessageStore) {
    self.store = store
  }

  func info(chatID: Int64) throws -> ChatInfo? {
    if let cached = infoCache[chatID] { return cached }
    if let info = try store.chatInfo(chatID: chatID) {
      infoCache[chatID] = info
      return info
    }
    return nil
  }

  func participants(chatID: Int64) throws -> [String] {
    if let cached = participantsCache[chatID] { return cached }
    let participants = try store.participants(chatID: chatID)
    participantsCache[chatID] = participants
    return participants
  }
}

extension RPCServer {
  func sendViaBridge(
    chatGUID: String,
    text: String,
    file: String,
    selectedMessageGuid: String? = nil,
    textFormatting: Any? = nil
  ) async throws -> [String: Any] {
    let action: BridgeAction = file.isEmpty ? .sendMessage : .sendAttachment
    if !file.isEmpty {
      let requiresMetadata = !text.isEmpty || selectedMessageGuid != nil || textFormatting != nil
      if requiresMetadata {
        let status: [String: Any]
        do {
          status = try await invokeBridge(action: .status, params: [:])
        } catch {
          throw DeliveryFailure(
            disposition: .notStarted,
            transport: .bridgeV2,
            operation: action.rawValue,
            detail: "Bridge capability inspection failed before the send was published."
          )
        }
        guard status["attachment_metadata"] as? Bool == true else {
          throw RPCError.internalError(
            "running bridge does not support captioned or threaded attachments; "
              + "restart Messages with the current imsg bridge"
          )
        }
      }
      let stagedFile: String
      do {
        stagedFile = try stageAttachment(file)
      } catch {
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "The attachment could not be staged before bridge dispatch."
        )
      }
      var params: [String: Any] = [
        "chatGuid": chatGUID, "filePath": stagedFile, "isAudioMessage": false,
      ]
      if !text.isEmpty {
        params["message"] = text
      }
      if let selectedMessageGuid {
        params["selectedMessageGuid"] = selectedMessageGuid
      }
      if let textFormatting {
        params["textFormatting"] = textFormatting
      }
      return try await invokeBridge(action: .sendAttachment, params: params)
    }
    var params: [String: Any] = ["chatGuid": chatGUID, "message": text]
    if let selectedMessageGuid {
      params["selectedMessageGuid"] = selectedMessageGuid
    }
    if let textFormatting {
      params["textFormatting"] = textFormatting
    }
    return try await invokeBridge(action: .sendMessage, params: params)
  }
}
