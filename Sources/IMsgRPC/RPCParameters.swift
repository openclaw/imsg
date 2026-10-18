import CoreFoundation
import Foundation

struct RPCParameters {
  private let values: [String: Any]

  init(_ values: [String: Any], method: String, supportedKeys: Set<String>) throws {
    if let unknown = values.keys.filter({ !supportedKeys.contains($0) }).sorted().first {
      throw RPCError.invalidParams("unknown \(method) param: \(unknown)")
    }
    self.values = values
  }

  func contains(_ key: String) -> Bool {
    values.keys.contains(key)
  }

  func string(_ key: String, aliases: [String] = []) throws -> String? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard let value = value as? String else {
      throw RPCError.invalidParams("\(name) must be a string")
    }
    return value
  }

  func integer(_ key: String, aliases: [String] = []) throws -> Int? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard let number = strictIntegerNumber(value), let parsed = Int(number.stringValue) else {
      throw RPCError.invalidParams("\(name) must be an integer")
    }
    return parsed
  }

  func int64(_ key: String, aliases: [String] = []) throws -> Int64? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard let number = strictIntegerNumber(value), let parsed = Int64(number.stringValue) else {
      throw RPCError.invalidParams("\(name) must be an integer")
    }
    return parsed
  }

  func boolean(_ key: String, aliases: [String] = []) throws -> Bool? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      throw RPCError.invalidParams("\(name) must be a boolean")
    }
    return number.boolValue
  }

  func stringArray(_ key: String, aliases: [String] = []) throws -> [String]? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard let rawValues = value as? [Any] else {
      throw RPCError.invalidParams("\(name) must be an array of strings")
    }
    var result: [String] = []
    result.reserveCapacity(rawValues.count)
    for rawValue in rawValues {
      guard let string = rawValue as? String else {
        throw RPCError.invalidParams("\(name) must be an array of strings")
      }
      result.append(string)
    }
    return result
  }

  func objectArray(_ key: String, aliases: [String] = []) throws -> [[String: Any]]? {
    guard let (name, value) = try selected(key, aliases: aliases) else { return nil }
    guard let rawValues = value as? [Any] else {
      throw RPCError.invalidParams("\(name) must be an array of objects")
    }
    var result: [[String: Any]] = []
    result.reserveCapacity(rawValues.count)
    for rawValue in rawValues {
      guard let object = rawValue as? [String: Any] else {
        throw RPCError.invalidParams("\(name) must be an array of objects")
      }
      result.append(object)
    }
    return result
  }

  func chatTarget(required: Bool = true) throws -> ChatTargetInput {
    let selectorKeys = ["chat_id", "chat_identifier", "chat_guid"]
    let supplied = selectorKeys.filter(contains)
    if supplied.count > 1 || (required && supplied.count != 1) {
      throw RPCError.invalidParams(
        "exactly one of chat_id, chat_identifier, or chat_guid is required"
      )
    }
    guard let key = supplied.first else {
      return ChatTargetInput(recipient: "", chatID: nil, chatIdentifier: "", chatGUID: "")
    }
    switch key {
    case "chat_id":
      guard let chatID = try int64("chat_id"), chatID > 0 else {
        throw RPCError.invalidParams("chat_id must be a positive integer")
      }
      return ChatTargetInput(
        recipient: "", chatID: chatID, chatIdentifier: "", chatGUID: "")
    case "chat_identifier":
      guard let identifier = try string("chat_identifier"), !identifier.isEmpty else {
        throw RPCError.invalidParams("chat_identifier must be a non-empty string")
      }
      return ChatTargetInput(
        recipient: "", chatID: nil, chatIdentifier: identifier, chatGUID: "")
    case "chat_guid":
      guard let guid = try string("chat_guid"), !guid.isEmpty else {
        throw RPCError.invalidParams("chat_guid must be a non-empty string")
      }
      return ChatTargetInput(recipient: "", chatID: nil, chatIdentifier: "", chatGUID: guid)
    default:
      preconditionFailure("unsupported chat selector")
    }
  }

  func recipientOrChatTarget() throws -> ChatTargetInput {
    let hasRecipient = contains("to")
    let selectorCount = ["chat_id", "chat_identifier", "chat_guid"].filter(contains).count
    if hasRecipient && selectorCount > 0 {
      throw RPCError.invalidParams("use to or exactly one chat selector; not both")
    }
    if hasRecipient {
      guard let recipient = try string("to"), !recipient.isEmpty else {
        throw RPCError.invalidParams("to must be a non-empty string")
      }
      return ChatTargetInput(
        recipient: recipient, chatID: nil, chatIdentifier: "", chatGUID: "")
    }
    return try chatTarget()
  }

  private func selected(_ key: String, aliases: [String]) throws -> (String, Any)? {
    let keys = [key] + aliases
    let supplied = keys.filter(contains)
    guard supplied.count <= 1 else {
      throw RPCError.invalidParams("use only one of \(keys.joined(separator: ", "))")
    }
    guard let name = supplied.first, let value = values[name] else { return nil }
    guard !(value is NSNull) else {
      throw RPCError.invalidParams("\(name) must not be null")
    }
    return (name, value)
  }

  private func strictIntegerNumber(_ value: Any) -> NSNumber? {
    guard let number = value as? NSNumber else { return nil }
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let type = String(cString: number.objCType)
    guard !["f", "d", "D"].contains(type) else { return nil }
    return number
  }
}

enum RPCParameterKeys {
  static let chatTarget: Set<String> = ["chat_id", "chat_identifier", "chat_guid"]
  static let replyTarget: Set<String> = [
    "reply_to", "replyTo", "reply_to_guid", "message_guid",
  ]
  static let messageTarget: Set<String> = [
    "message_id", "messageId", "message_guid", "messageGuid", "message",
  ]
  static let partIndex: Set<String> = ["part_index", "partIndex"]

  static func combining(_ sets: Set<String>...) -> Set<String> {
    sets.reduce(into: Set<String>()) { result, set in
      result.formUnion(set)
    }
  }
}
