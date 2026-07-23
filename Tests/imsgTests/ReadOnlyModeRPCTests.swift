import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func int64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcReadOnlyRejectsMutatingMethod() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  let line = #"{"jsonrpc":"2.0","id":"7","method":"send","params":{"to":"+15551234567","text":"hi"}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 1)
  let envelope = output.errors[0]
  // JSON-RPC framing is preserved: id is echoed.
  #expect(envelope["id"] as? String == "7")
  let error = envelope["error"] as? [String: Any]
  #expect(int64(error?["code"]) == -32001)
  #expect(error?["data"] as? String == "send")
}

@Test
func rpcReadOnlyRejectsRepresentativeMutations() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  for method in ["tapback", "message.delete", "chats.markUnread", "group.leave", "typing", "read"] {
    let output = TestRPCOutput()
    let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)
    let line = #"{"jsonrpc":"2.0","id":"1","method":"\#(method)","params":{}}"#
    await server.handleLineForTesting(line)
    let error = output.errors.first?["error"] as? [String: Any]
    #expect(int64(error?["code"]) == -32001, "\(method) should be refused in read-only mode")
  }
}

@Test
func rpcReadOnlyStillServesReadMethods() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  let line = #"{"jsonrpc":"2.0","id":"9","method":"chats.list","params":{"limit":10}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.isEmpty)
  #expect(output.responses.count == 1)
}

@Test
func rpcReadWriteServerStillSendsWhenNotReadOnly() async throws {
  // Sanity: without read-only, a mutating method is not blocked by the gate
  // (it may still fail for other reasons, but never with the read-only code).
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"send","params":{"to":"+1"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64(error?["code"]) != -32001)
}

@Test
func rpcMethodClassificationIsComplete() {
  let supported = Set(kSupportedRPCMethods)
  // Every advertised method is classified as exactly one of read or mutating.
  #expect(kReadOnlyRPCMethods.isDisjoint(with: kMutatingRPCMethods))
  #expect(kReadOnlyRPCMethods.union(kMutatingRPCMethods) == supported)
  // Read methods must never be treated as mutating.
  #expect(kReadOnlyRPCMethods.isSubset(of: supported))
}
