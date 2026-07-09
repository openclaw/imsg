import CoreFoundation
import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesStats(id: Any?, params: [String: Any]) async throws {
    let supportedParams: Set<String> = ["chat_id", "include_media", "time_zone"]
    if let unknown = params.keys.filter({ !supportedParams.contains($0) }).sorted().first {
      throw RPCError.invalidParams("unknown messages.stats param: \(unknown)")
    }

    let chatID: Int64?
    if let value = params["chat_id"] {
      guard let parsed = strictStatsInt64(value) else {
        throw RPCError.invalidParams("chat_id must be an integer")
      }
      chatID = parsed
    } else {
      chatID = nil
    }

    let includeMedia: Bool
    if let value = params["include_media"] {
      guard let parsed = strictStatsBool(value) else {
        throw RPCError.invalidParams("include_media must be a boolean")
      }
      includeMedia = parsed
    } else {
      includeMedia = false
    }

    let timeZone: String?
    if let value = params["time_zone"] {
      guard let parsed = value as? String else {
        throw RPCError.invalidParams("time_zone must be a string")
      }
      timeZone = parsed
    } else {
      timeZone = nil
    }

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

private func strictStatsInt64(_ value: Any) -> Int64? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  return Int64(number.stringValue)
}

private func strictStatsBool(_ value: Any) -> Bool? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
  return number.boolValue
}

private func dictionary<T: Encodable>(from value: T) throws -> [String: Any] {
  let data = try JSONEncoder().encode(value)
  let json = try JSONSerialization.jsonObject(with: data)
  guard let dictionary = json as? [String: Any] else {
    throw RPCError.internalError("statistics encoding did not produce an object")
  }
  return dictionary
}
