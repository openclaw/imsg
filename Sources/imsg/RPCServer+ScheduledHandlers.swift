import CoreFoundation
import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesScheduled(params: [String: Any], id: Any?) async throws {
    let supportedParams: Set<String> = ["limit"]
    if let unknown = params.keys.filter({ !supportedParams.contains($0) }).sorted().first {
      throw RPCError.invalidParams("unknown messages.scheduled param: \(unknown)")
    }

    let limit: Int
    if let value = params["limit"] {
      guard let parsed = strictScheduledLimit(value) else {
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

private func strictScheduledLimit(_ value: Any) -> Int? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  guard let parsed = Int(number.stringValue), parsed > 0 else { return nil }
  return parsed
}
