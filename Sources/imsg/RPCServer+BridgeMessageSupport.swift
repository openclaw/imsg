import Foundation
import IMsgCore

func rpcPollOptionsParam(_ params: RPCParameters) throws -> [String] {
  guard let values = try params.stringArray("options", aliases: ["option"]) else {
    throw RPCError.invalidParams("options is required")
  }

  let options = values.compactMap { value -> String? in
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if options.count < 2 {
    throw RPCError.invalidParams("at least two poll options are required")
  }
  return options
}

func rpcMessageGUIDParam(_ params: RPCParameters) throws -> String? {
  let raw = try params.string(
    "message_id", aliases: ["messageId", "message_guid", "messageGuid", "message"])
  let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return trimmed.isEmpty ? nil : trimmed
}

func normalizeBridgeReactionType(_ raw: String, remove: Bool = false) throws -> String {
  var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if value.isEmpty {
    throw RPCError.invalidParams("reaction, kind, or emoji is required")
  }
  var shouldRemove = remove
  if value.hasPrefix("remove-") {
    shouldRemove = true
    value.removeFirst("remove-".count)
  }
  let normalized: String
  switch value {
  case "love", "heart", "❤️", "❤":
    normalized = "love"
  case "like", "thumbsup", "thumbs-up", "+1", "👍":
    normalized = "like"
  case "dislike", "thumbsdown", "thumbs-down", "-1", "👎":
    normalized = "dislike"
  case "laugh", "haha", "lol", "😂", "🤣":
    normalized = "laugh"
  case "emphasize", "emphasis", "!!", "‼", "‼️":
    normalized = "emphasize"
  case "question", "?", "❓":
    normalized = "question"
  default:
    throw RPCError.invalidParams(
      "unsupported tapback reaction \(raw); use love, like, dislike, laugh, emphasize, or question"
    )
  }
  let result = shouldRemove ? "remove-\(normalized)" : normalized
  guard BridgeReactionKind(rawValue: result) != nil else {
    throw RPCError.invalidParams("unsupported tapback reaction \(raw)")
  }
  return result
}
