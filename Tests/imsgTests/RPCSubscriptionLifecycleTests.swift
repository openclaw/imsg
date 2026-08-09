import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private final class BlockingContactResolver: ContactResolving, @unchecked Sendable {
  let contactsUnavailable = false

  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func displayName(for handle: String) -> String? {
    entered.signal()
    release.wait()
    return nil
  }

  func displayNames(for handles: [String]) -> [String: String] { [:] }
  func searchByName(_ query: String) -> [ContactMatch] { [] }

  func waitUntilBlocked() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { [entered] in
        entered.wait()
        continuation.resume()
      }
    }
  }

  func unblock() {
    release.signal()
  }
}

@Test(.timeLimit(.minutes(1)))
func rpcUnsubscribeResponseIsFinalAndCancellationIsSilent() async throws {
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(
    output: output,
    probe: MutationProbe(),
    watchSource: source
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await source.waitForStreams(1)
  source.yield(
    Message(
      rowID: 5,
      chatID: 1,
      sender: "+123",
      text: "before unsubscribe",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  )
  await output.waitForOutputCount(2)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )
  await source.waitForTerminations(1)
  await server.subscriptions.waitUntilEmpty()

  let outputsAtUnsubscribe = output.outputs.count
  let terminated = source.yield(
    Message(
      rowID: 6,
      chatID: 1,
      sender: "+123",
      text: "after unsubscribe",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  )
  #expect(terminated)
  #expect(output.outputs.count == outputsAtUnsubscribe)
  #expect(output.outputs.last?["id"] as? String == "unsubscribe")
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "error" })
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "watch.overflow" })
}

@Test(.timeLimit(.minutes(1)))
func rpcQueuedSubscribeAfterEOFClosureReturnsBusyWithoutZombie() async throws {
  let source = ControlledWatchSource()
  let resolver = BlockingContactResolver()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(
    output: output,
    probe: MutationProbe(),
    watchSource: source,
    contactResolver: resolver
  )
  defer { resolver.unblock() }

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"active","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await source.waitForStreams(1)
  source.yield(
    Message(
      rowID: 5,
      chatID: 1,
      sender: "+123",
      text: "block subscription completion",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  )
  await resolver.waitUntilBlocked()

  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }
  input.yield(
    #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )
  await server.subscriptions.waitUntilEmpty()

  input.yield(
    #"{"jsonrpc":"2.0","id":"queued","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  input.finish()
  await server.subscriptions.waitUntilClosed()

  resolver.unblock()
  await source.waitForTerminations(1)
  try await run.value

  #expect(output.responses.allSatisfy { $0["id"] as? String != "queued" })
  let queuedError = try #require(output.errors.first { $0["id"] as? String == "queued" })
  let error = try #require(queuedError["error"] as? [String: Any])
  #expect(error["code"] as? Int == -32000)
  #expect(error["data"] as? String == "server is shutting down")
  #expect(await server.subscriptions.count == 0)
}
