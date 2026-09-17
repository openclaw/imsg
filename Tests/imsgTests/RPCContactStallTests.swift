import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

#if os(macOS)
  private final class StalledRPCContacts: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var blocked = false
    private var loads = 0

    var loadCount: Int { lock.withLock { loads } }

    var source: ContactCatalogSource {
      ContactCatalogSource(
        authorization: { .authorized },
        load: { [self] in
          let shouldBlock = lock.withLock {
            loads += 1
            return blocked
          }
          if shouldBlock { release.wait() }
          return [ContactCatalogRecord(name: "Alice", phones: ["+123"], emails: [])]
        },
        observeChanges: { _ in {} }
      )
    }

    func block() { lock.withLock { blocked = true } }
    func unblock() { release.signal() }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func rpcWatchDeliversWhileContactsLoadIsBlocked(warmCache: Bool) async throws {
    let source = StalledRPCContacts()
    let contacts = ContactResolver(region: "US", source: source.source, refreshInterval: 60)
    if warmCache {
      #expect(contacts.displayName(for: "+123") == "Alice")
    }
    source.block()
    contacts.invalidate()
    defer { source.unblock() }

    let output = TestRPCOutput()
    let store = try CommandTestDatabase.makeStoreForRPC()
    let original = try #require(store.messagesAfter(afterRowID: 4, chatID: nil, limit: 1).first)
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      isBridgeReady: { false },
      contactResolver: contacts,
      watchStreamProvider: { watcher, chatID, sinceRowID, configuration, filter in
        var configuration = configuration
        configuration.fallbackPollInterval = 0.01
        return watcher.stream(
          chatID: chatID, sinceRowID: sinceRowID, configuration: configuration, filter: filter)
      }
    )
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":4}}"#
    )
    try await waitForContactStallProof {
      !output.notifications.isEmpty && source.loadCount == (warmCache ? 2 : 1)
    }
    #expect(source.loadCount == (warmCache ? 2 : 1))
    #expect(output.notifications.count == 1)
    let params = output.notifications.first?["params"] as? [String: Any]
    let message = params?["message"] as? [String: Any]
    #expect(rpcTestInt64Value(message?["id"]) == 5)
    #expect(message?["text"] as? String == "hello")
    #expect(message?["sender_name"] as? String == (warmCache ? "Alice" : nil))
    #expect(message?["created_at"] as? String == CLIISO8601.format(original.date))

    try store.withConnection { db in
      try db.run(
        """
        INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
        VALUES (6, 1, 'still live', ?, 0, 'iMessage')
        """, CommandTestDatabase.appleEpoch(original.date))
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
    }
    try await waitForContactStallProof { output.notifications.count == 2 }
    #expect(output.notifications.count == 2)
    let nextParams = output.notifications.last?["params"] as? [String: Any]
    let nextMessage = nextParams?["message"] as? [String: Any]
    #expect(rpcTestInt64Value(nextMessage?["id"]) == 6)

    let control = Task {
      await server.handleLineForTesting(
        #"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
      await server.handleLineForTesting(
        #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
      )
    }
    try await waitForContactStallProof { output.responses.count == 3 }
    #expect(output.responses.last?["id"] as? String == "unsubscribe")
    let health =
      output.responses.first { $0["id"] as? String == "status" }?["result"]
      as? [String: Any]
    #expect((health?["contacts"] as? [String: Any])?["available"] as? Bool == warmCache)
    #expect(source.loadCount == (warmCache ? 2 : 1))
    #expect(output.errors.isEmpty)
    #expect(output.notifications.allSatisfy { $0["method"] as? String == "message" })

    // Cleanup also lets this regression fail without leaving a blocked subscription behind.
    source.unblock()
    await control.value
    await server.subscriptions.cancelAll()
  }

  private func waitForContactStallProof(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
#endif
