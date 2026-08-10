import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

#if os(macOS)
  private final class RPCContactSource: @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationValue: ContactCatalogAuthorization
    private var recordsValue: [ContactCatalogRecord]

    init(
      authorization: ContactCatalogAuthorization,
      records: [ContactCatalogRecord]
    ) {
      self.authorizationValue = authorization
      self.recordsValue = records
    }

    var source: ContactCatalogSource {
      ContactCatalogSource(
        authorization: { [self] in lock.withLock { authorizationValue } },
        load: { [self] in lock.withLock { recordsValue } },
        observeChanges: { _ in {} }
      )
    }

    func setAuthorization(_ authorization: ContactCatalogAuthorization) {
      lock.withLock { authorizationValue = authorization }
    }
  }

  private final class RPCContactClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 11 } }
  }

  @Test
  func rpcContactNameSendUsesRequestRegion() async throws {
    let source = RPCContactSource(
      authorization: .authorized,
      records: [
        ContactCatalogRecord(name: "Alice", phones: ["07700 900000"], emails: [])
      ]
    )
    let contacts = ContactResolver(region: "US", source: source.source)
    let store = try CommandTestDatabase.makeStoreForRPC()
    let output = TestRPCOutput()
    var sent: MessageSendOptions?
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      sendMessage: { sent = $0 },
      resolveSentMessage: resolvedSentMessageFixture,
      isBridgeReady: { false },
      contactResolver: contacts
    )

    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"gb","method":"send","params":{"to":"Alice","text":"hello","region":"GB"}}"#
    )

    #expect(sent?.recipient == "+447700900000")
    #expect(sent?.region == "GB")
    #expect(output.errors.isEmpty)
  }

  @Test
  func rpcStatusTracksLiveContactOwnerHealth() async throws {
    let clock = RPCContactClock()
    let source = RPCContactSource(
      authorization: .unavailable,
      records: [
        ContactCatalogRecord(name: "Alice", phones: ["+15551234567"], emails: [])
      ]
    )
    let contacts = ContactResolver(
      region: "US",
      source: source.source,
      refreshInterval: 10,
      now: clock.now
    )
    let output = TestRPCOutput()
    let server = RPCServer(
      store: try CommandTestDatabase.makeStoreForRPC(),
      verbose: false,
      output: output,
      isBridgeReady: { false },
      contactResolver: contacts
    )

    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"before","method":"status","params":{}}"#)
    source.setAuthorization(.authorized)
    clock.advance()
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"after","method":"status","params":{}}"#)

    let before = rpcContactsAvailable(output, id: "before")
    let after = rpcContactsAvailable(output, id: "after")
    #expect(before == false)
    #expect(after == true)
  }

  private func rpcContactsAvailable(_ output: TestRPCOutput, id: String) -> Bool? {
    let response = output.responses.first { $0["id"] as? String == id }
    let result = response?["result"] as? [String: Any]
    let contacts = result?["contacts"] as? [String: Any]
    return contacts?["available"] as? Bool
  }
#endif
