import Foundation
import IMsgCore

extension RPCServer {
  func handleServerGetMessageStats(id: Any?, params: [String: Any]) async throws {
    let chatID = int64Param(params["chat_id"] ?? params["chatID"])
    let includeMedia =
      boolParam(params["media"] ?? params["include_media"] ?? params["includeMedia"]) ?? false
    let stats = try store.messageStats(chatID: chatID, includeMedia: includeMedia)
    respond(id: id, result: try dictionary(from: stats))
  }

  func handleGetMediaStatistics(id: Any?, params: [String: Any]) async throws {
    let chatID = int64Param(params["chat_id"] ?? params["chatID"])
    let stats = try store.mediaStats(chatID: chatID)
    respond(id: id, result: try dictionary(from: stats))
  }

  func handleGetMediaStatisticsByChat(id: Any?, params: [String: Any]) async throws {
    guard let chatID = int64Param(params["chat_id"] ?? params["chatID"]) else {
      throw RPCError.invalidParams("chat_id is required")
    }
    let stats = try store.mediaStats(chatID: chatID)
    respond(id: id, result: try dictionary(from: stats))
  }
}

private func dictionary<T: Encodable>(from value: T) throws -> [String: Any] {
  let data = try JSONEncoder().encode(value)
  let json = try JSONSerialization.jsonObject(with: data)
  return (json as? [String: Any]) ?? [:]
}
