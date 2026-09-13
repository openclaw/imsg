import Foundation
import SQLite
import Testing

@testable import IMsgCore

let testPollBundleID =
  "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls"

func pollURL(queryName: String, object: [String: Any]) throws -> URL {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let encoded = data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  var components = URLComponents()
  components.scheme = "messages-polls"
  components.host = "poll"
  components.queryItems = [
    URLQueryItem(name: "source", value: "sendMenu"),
    URLQueryItem(name: queryName, value: encoded),
  ]
  return try #require(components.url)
}

func applePollEnvelopePayload(jsonObject: [String: Any], query: String = "") throws
  -> Data
{
  let json = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
  let encoded = json.base64EncodedString()
  let suffix = query.isEmpty ? "" : "?\(query)"
  let url = try #require(URL(string: "data:,\(encoded)\(suffix)"))
  return try NSKeyedArchiver.archivedData(
    withRootObject: [
      "URL": url,
      "sessionIdentifier": UUID(),
      "an": "Polls",
    ],
    requiringSecureCoding: false
  )
}
