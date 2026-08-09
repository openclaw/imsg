import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesStats(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "messages.stats",
      supportedKeys: ["chat_id", "include_media", "time_zone"]
    )

    let chatID: Int64?
    if params.contains("chat_id") {
      guard let parsed = try params.int64("chat_id") else {
        throw RPCError.invalidParams("chat_id must be an integer")
      }
      chatID = parsed
    } else {
      chatID = nil
    }

    let includeMedia: Bool
    includeMedia = try params.boolean("include_media") ?? false

    let timeZone: String?
    timeZone = try params.string("time_zone")

    do {
      let stats = try store.messageStats(
        chatID: chatID,
        includeMedia: includeMedia,
        timeZoneIdentifier: timeZone
      )
      respond(id: id, result: try dictionary(from: stats))
    } catch let error as MessageStatsError {
      throw RPCError.invalidParams(error.description)
    }
  }
}

private func dictionary<T: Encodable>(from value: T) throws -> [String: Any] {
  let data = try JSONEncoder().encode(value)
  let json = try JSONSerialization.jsonObject(with: data)
  guard let dictionary = json as? [String: Any] else {
    throw RPCError.internalError("statistics encoding did not produce an object")
  }
  return dictionary
}
