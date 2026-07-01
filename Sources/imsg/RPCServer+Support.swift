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

struct RPCError: Error {
  let code: Int
  let message: String
  let data: String?

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

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let data {
      dict["data"] = data
    }
    return dict
  }
}

actor SubscriptionStore {
  private var nextID = 1
  private var tasks: [Int: Task<Void, Never>] = [:]

  func allocateID() -> Int {
    let id = nextID
    nextID += 1
    return id
  }

  func insert(_ task: Task<Void, Never>, for id: Int) {
    tasks[id] = task
  }

  func remove(_ id: Int) -> Task<Void, Never>? {
    tasks.removeValue(forKey: id)
  }

  func cancelAll() {
    for task in tasks.values {
      task.cancel()
    }
    tasks.removeAll()
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
    if !file.isEmpty {
      let requiresMetadata = !text.isEmpty || selectedMessageGuid != nil || textFormatting != nil
      if requiresMetadata {
        let status = try await bridgeInvoker(.status, [:])
        guard status["attachment_metadata"] as? Bool == true else {
          throw RPCError.internalError(
            "running bridge does not support captioned or threaded attachments; "
              + "restart Messages with the current imsg bridge"
          )
        }
      }
      let stagedFile = try stageAttachment(file)
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
      return try await bridgeInvoker(.sendAttachment, params)
    }
    var params: [String: Any] = ["chatGuid": chatGUID, "message": text]
    if let selectedMessageGuid {
      params["selectedMessageGuid"] = selectedMessageGuid
    }
    if let textFormatting {
      params["textFormatting"] = textFormatting
    }
    return try await bridgeInvoker(.sendMessage, params)
  }
}
