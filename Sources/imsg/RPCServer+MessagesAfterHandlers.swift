import Foundation
import IMsgCore

extension RPCServer {
  func handleMessagesAfter(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "messages.after",
      supportedKeys: [
        "since_rowid",
        "chat_id",
        "limit",
        "attachments",
        "convert_attachments",
        "include_reactions",
      ]
    )

    guard let sinceRowID = try params.int64("since_rowid") else {
      throw RPCError.invalidParams("since_rowid must be an integer")
    }

    let chatID: Int64?
    if params.contains("chat_id") {
      guard let parsed = try params.int64("chat_id"), parsed > 0 else {
        throw RPCError.invalidParams("chat_id must be a positive integer")
      }
      chatID = parsed
    } else {
      chatID = nil
    }

    let limit: Int
    if params.contains("limit") {
      guard let parsed = try params.integer("limit"), (1...500).contains(parsed) else {
        throw RPCError.invalidParams("limit must be an integer between 1 and 500")
      }
      limit = parsed
    } else {
      limit = 100
    }

    let includeAttachments = try params.boolean("attachments") ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: try params.boolean("convert_attachments") ?? false)
    let database = try await databaseResources.require()
    let store = database.store
    let page = try store.messagesAfterPage(
      afterRowID: sinceRowID,
      chatID: chatID,
      limit: limit,
      includeReactions: try params.boolean("include_reactions") ?? false
    )
    let reactionsByMessageID = try store.reactions(for: page.messages)
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(page.messages.count)
    for message in page.messages {
      payloads.append(
        try buildMessagePayload(
          store: store,
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
