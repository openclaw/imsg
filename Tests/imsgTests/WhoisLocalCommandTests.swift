import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import IMsgRPC
@testable import imsg

private func emptyStore() throws -> MessageStore {
  let db = try Connection(.inMemory)
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func whoisLocalReportsIMessageText() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["address": ["friend@example.com"]],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await WhoisCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyStore() },
      resolveService: { _, _ in .imessage }
    )
  }
  #expect(output.contains("whois friend@example.com: imessage"))
  #expect(output.contains("known=true"))
}

@Test
func whoisLocalReportsSMSJson() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["address": ["+15551234567"]],
    flags: ["local", "jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await WhoisCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyStore() },
      resolveService: { _, _ in .sms }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["address"] as? String == "+15551234567")
  #expect(payload["service"] as? String == "sms")
  #expect(payload["known"] as? Bool == true)
  #expect(payload["source"] as? String == "local")
}

@Test
func whoisLocalReportsUnknownForNewContact() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["address": ["+15559998888"]],
    flags: ["local", "jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await WhoisCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyStore() },
      resolveService: { _, _ in .unknown }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["service"] as? String == "unknown")
  #expect(payload["known"] as? Bool == false)
}

@Test
func whoisLocalDoesNotInvokeBridge() async throws {
  // The local path must resolve purely from the injected store/resolver and
  // never touch the IMCore bridge (which would require SIP).
  let values = ParsedValues(
    positional: [],
    options: ["address": ["friend@example.com"]],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var resolverCalled = false
  _ = try await StdoutCapture.capture {
    try await WhoisCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyStore() },
      resolveService: { _, _ in
        resolverCalled = true
        return .imessage
      }
    )
  }
  #expect(resolverCalled)
}

@Test
func whoisLocalRequiresAddress() async {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await WhoisCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyStore() },
      resolveService: { _, _ in .imessage }
    )
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
