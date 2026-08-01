import CoreFoundation
import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesAfter(id: Any?, params: [String: Any]) async throws {
    let supportedParams: Set<String> = [
      "since_rowid",
      "chat_id",
      "limit",
      "attachments",
      "convert_attachments",
      "include_reactions",
    ]
    if let unknown = params.keys.filter({ !supportedParams.contains($0) }).sorted().first {
      throw RPCError.invalidParams("unknown messages.after param: \(unknown)")
    }

    guard let sinceRowID = strictMessagesAfterInt64(params["since_rowid"]), sinceRowID >= 0 else {
      throw RPCError.invalidParams("since_rowid must be a non-negative integer")
    }

    let chatID: Int64?
    if let rawChatID = params["chat_id"] {
      guard let parsed = strictMessagesAfterInt64(rawChatID), parsed > 0 else {
        throw RPCError.invalidParams("chat_id must be a positive integer")
      }
      chatID = parsed
    } else {
      chatID = nil
    }

    let limit: Int
    if let rawLimit = params["limit"] {
      guard let parsed = strictMessagesAfterInt(rawLimit), (1...500).contains(parsed) else {
        throw RPCError.invalidParams("limit must be an integer between 1 and 500")
      }
      limit = parsed
    } else {
      limit = 100
    }

    let includeAttachments = try strictMessagesAfterBool(
      params["attachments"],
      name: "attachments"
    )
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: try strictMessagesAfterBool(
        params["convert_attachments"],
        name: "convert_attachments"
      ))
    let page = try store.messagesAfterPage(
      afterRowID: sinceRowID,
      chatID: chatID,
      limit: limit,
      includeReactions: try strictMessagesAfterBool(
        params["include_reactions"],
        name: "include_reactions"
      )
    )
    let reactionsByMessageID = try store.reactions(for: page.messages)
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(page.messages.count)
    for message in page.messages {
      payloads.append(
        try await buildMessagePayload(
          store: store,
          cache: cache,
          message: message,
          includeAttachments: includeAttachments,
          includeReactions: true,
          prefetchedReactions: reactionsByMessageID[message.rowID] ?? [],
          attachmentOptions: attachmentOptions,
          contactResolver: contactResolver
        ))
    }

    respond(
      id: id,
      result: [
        "messages": payloads,
        "next_rowid": page.nextRowID,
        "has_more": page.hasMore,
      ]
    )
  }
}

private func strictMessagesAfterInt64(_ value: Any?) -> Int64? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  return Int64(number.stringValue)
}

private func strictMessagesAfterInt(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber else { return nil }
  guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  return Int(number.stringValue)
}

private func strictMessagesAfterBool(_ value: Any?, name: String) throws -> Bool {
  guard let value else { return false }
  guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
    throw RPCError.invalidParams("\(name) must be a boolean")
  }
  return number.boolValue
}
