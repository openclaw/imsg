import Foundation

@testable import imsg

final class TestRPCOutput: RPCOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var responseStorage: [[String: Any]] = []
  private var errorStorage: [[String: Any]] = []
  private var notificationStorage: [[String: Any]] = []
  private var outputStorage: [[String: Any]] = []
  private var outputWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  var responses: [[String: Any]] { snapshot(.response) }
  var errors: [[String: Any]] { snapshot(.error) }
  var notifications: [[String: Any]] { snapshot(.notification) }
  var outputs: [[String: Any]] { snapshot(.all) }

  func sendResponse(id: Any, result: Any) {
    record(.response, value: ["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    record(.error, value: payload)
  }

  func sendNotification(method: String, params: Any) {
    record(
      .notification,
      value: ["jsonrpc": "2.0", "method": method, "params": params]
    )
  }

  func flush() {}

  func waitForOutputCount(_ count: Int) async {
    if outputs.count >= count { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if outputStorage.count >= count {
        lock.unlock()
        continuation.resume()
      } else {
        outputWaiters.append((count, continuation))
        lock.unlock()
      }
    }
  }

  private enum OutputKind {
    case response
    case error
    case notification
  }

  private enum SnapshotKind {
    case response
    case error
    case notification
    case all
  }

  private func record(_ kind: OutputKind, value: [String: Any]) {
    let ready: [CheckedContinuation<Void, Never>]
    lock.lock()
    switch kind {
    case .response:
      responseStorage.append(value)
    case .error:
      errorStorage.append(value)
    case .notification:
      notificationStorage.append(value)
    }
    outputStorage.append(value)
    let currentCount = outputStorage.count
    ready = outputWaiters.filter { $0.count <= currentCount }.map(\.continuation)
    outputWaiters.removeAll { $0.count <= currentCount }
    lock.unlock()
    for continuation in ready {
      continuation.resume()
    }
  }

  private func snapshot(_ kind: SnapshotKind) -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    switch kind {
    case .response:
      return responseStorage
    case .error:
      return errorStorage
    case .notification:
      return notificationStorage
    case .all:
      return outputStorage
    }
  }
}
