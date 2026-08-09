import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesScheduled(params: [String: Any], id: Any?) async throws {
    let params = try RPCParameters(
      params, method: "messages.scheduled", supportedKeys: ["limit"])

    let limit: Int
    if params.contains("limit") {
      guard let parsed = try params.integer("limit"), parsed > 0 else {
        throw RPCError.invalidParams("limit must be a positive integer")
      }
      limit = parsed
    } else {
      limit = 50
    }

    do {
      let messages = try store.scheduledMessages(limit: limit)
      let payloads = try messages.map { message -> [String: Any] in
        let encoded = try JSONEncoder().encode(ScheduledMessagePayload(message))
        guard let payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
          throw RPCError.internalError("scheduled message encoding did not produce an object")
        }
        return payload
      }
      respond(id: id, result: ["messages": payloads])
    } catch let error as ScheduledMessagesError {
      throw RPCError.invalidParams(error.description)
    }
  }
}
