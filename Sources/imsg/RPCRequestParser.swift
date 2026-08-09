import CoreFoundation
import Foundation

struct RPCRequest {
  let id: Any?
  let method: String
  let params: [String: Any]

  var isNotification: Bool { id == nil }
}

struct RPCParseFailure {
  let id: Any?
  let error: RPCError
  let shouldRespond: Bool
}

enum RPCRequestParseResult {
  case success(RPCRequest)
  case failure(RPCParseFailure)
}

enum RPCRequestParser {
  static func parse(_ line: String) -> RPCRequestParseResult {
    guard let data = line.data(using: .utf8) else {
      return .failure(
        RPCParseFailure(id: nil, error: RPCError.parseError("invalid utf8"), shouldRespond: true))
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      return .failure(
        RPCParseFailure(
          id: nil, error: RPCError.parseError(error.localizedDescription), shouldRespond: true))
    }
    guard let request = json as? [String: Any] else {
      return .failure(
        RPCParseFailure(
          id: nil,
          error: RPCError.invalidRequest("request must be an object"),
          shouldRespond: true
        ))
    }
    let hasID = request.keys.contains("id")
    let id = request["id"]
    if hasID, !isValidID(id) {
      return .failure(
        RPCParseFailure(
          id: nil,
          error: RPCError.invalidRequest("id must be a string, number, or null"),
          shouldRespond: true
        ))
    }
    guard let jsonrpc = request["jsonrpc"] as? String, jsonrpc == "2.0" else {
      return .failure(
        RPCParseFailure(
          id: hasID ? id : nil,
          error: RPCError.invalidRequest("jsonrpc must be exactly 2.0"),
          shouldRespond: true
        ))
    }
    guard let method = request["method"] as? String, !method.isEmpty else {
      return .failure(
        RPCParseFailure(
          id: hasID ? id : nil,
          error: RPCError.invalidRequest("method is required"),
          shouldRespond: true
        ))
    }
    let params: [String: Any]
    if let rawParams = request["params"] {
      guard let namedParams = rawParams as? [String: Any] else {
        return .failure(
          RPCParseFailure(
            id: hasID ? id : nil,
            error: RPCError.invalidParams("params must be an object when present"),
            shouldRespond: hasID
          ))
      }
      params = namedParams
    } else {
      params = [:]
    }
    return .success(
      RPCRequest(
        id: hasID ? id : nil,
        method: method,
        params: params
      ))
  }

  private static func isValidID(_ value: Any?) -> Bool {
    guard let value else { return false }
    if value is NSNull || value is String { return true }
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
  }
}
