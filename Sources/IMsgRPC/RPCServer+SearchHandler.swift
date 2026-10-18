import Foundation

extension RPCServer {
  func handleMessagesSearch(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "messages.search",
      supportedKeys: ["query", "match", "limit"]
    )
    guard
      let query = try params.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
      !query.isEmpty
    else {
      throw RPCError.invalidParams("query must be a non-empty string")
    }
    let match = try params.string("match") ?? "contains"
    guard match == "contains" || match == "exact" else {
      throw RPCError.invalidParams("match must be contains or exact")
    }
    let limit = try params.integer("limit") ?? 50
    guard limit > 0, limit <= 100 else {
      throw RPCError.invalidParams("limit must be between 1 and 100")
    }

    let database = try await databaseResources.require()
    let messages = try database.store.searchMessages(query: query, match: match, limit: limit)
    let payloads = try messages.map {
      try buildMessagePayload(
        store: database.store,
        message: $0,
        includeAttachments: false,
        includeReactions: false,
        contactResolver: contactResolver
      )
    }
    respond(id: id, result: ["messages": payloads])
  }
}
