import Foundation

struct RPCRequest {
  let id: Any?
  let method: String
  let params: [String: Any]
  let paramsAreNamed: Bool
}

struct RPCParseFailure {
  let id: Any?
  let error: RPCError
}

enum RPCRequestParseResult {
  case success(RPCRequest)
  case failure(RPCParseFailure)
}

enum RPCRequestParser {
  static func parse(_ line: String) -> RPCRequestParseResult {
    guard let data = line.data(using: .utf8) else {
      return .failure(RPCParseFailure(id: nil, error: RPCError.parseError("invalid utf8")))
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      return .failure(
        RPCParseFailure(id: nil, error: RPCError.parseError(error.localizedDescription)))
    }
    guard let request = json as? [String: Any] else {
      return .failure(
        RPCParseFailure(id: nil, error: RPCError.invalidRequest("request must be an object")))
    }
    let id = request["id"]
    let jsonrpc = request["jsonrpc"] as? String
    if jsonrpc != nil && jsonrpc != "2.0" {
      return .failure(
        RPCParseFailure(id: id, error: RPCError.invalidRequest("jsonrpc must be 2.0")))
    }
    guard let method = request["method"] as? String, !method.isEmpty else {
      return .failure(RPCParseFailure(id: id, error: RPCError.invalidRequest("method is required")))
    }
    let rawParams = request["params"]
    let params = rawParams as? [String: Any] ?? [:]
    return .success(
      RPCRequest(
        id: id,
        method: method,
        params: params,
        paramsAreNamed: rawParams == nil || rawParams is [String: Any]
      ))
  }
}
