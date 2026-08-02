import Foundation
import Testing

@testable import IMsgCore

/// A v2 request that vanishes from the inbox without a reply can never be
/// answered: `MessagesLauncher` wipes both queue directories when it relaunches
/// Messages.app with the dylib. These cover the on-disk shapes the poll loop
/// distinguishes, so a live request is never mistaken for a discarded one.
@Suite("IMsgBridgeClient queue detection")
struct IMsgBridgeClientQueueTests {
  private func makeInbox() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("imsg-queue-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true
    )
    return dir
  }

  private func write(_ dir: String, _ name: String) {
    FileManager.default.createFile(
      atPath: (dir as NSString).appendingPathComponent(name),
      contents: Data("{}".utf8)
    )
  }

  private var client: IMsgBridgeClient {
    IMsgBridgeClient(launcher: MessagesLauncher.shared)
  }

  @Test
  func unclaimedRequestIsPending() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    write(inbox, "\(id).json")

    #expect(client.requestQueueState(inboxDir: inbox, id: id) == .unclaimed)
  }

  @Test
  func claimedRequestIsClaimed() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    // The dylib claims a request by renaming it to `<id>.processing.<pid>`
    // (see processV2InboxFile); that is still in flight, not discarded.
    write(inbox, "\(id).processing.4242")

    #expect(client.requestQueueState(inboxDir: inbox, id: id) == .claimed)
  }

  @Test
  func missingRequestIsAbsent() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    // An unrelated request must not keep ours alive.
    write(inbox, "\(UUID().uuidString).json")

    #expect(client.requestQueueState(inboxDir: inbox, id: UUID().uuidString) == .absent)
  }

  @Test
  func unreadableInboxFailsSafeAsPending() {
    // Cannot enumerate: keep waiting rather than ending a live request.
    #expect(
      client.requestQueueState(
        inboxDir: "/nonexistent/imsg-queue-tests", id: UUID().uuidString
      ) == .unclaimed
    )
  }

  /// Both observable paths can end absent. The client must not infer delivery
  /// safety from whether it happened to observe the short-lived claim state.
  @Test
  func absentStateDoesNotEncodeClaimHistory() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }

    let neverClaimed = UUID().uuidString
    write(inbox, "\(neverClaimed).json")
    #expect(client.requestQueueState(inboxDir: inbox, id: neverClaimed) == .unclaimed)
    try FileManager.default.removeItem(
      atPath: (inbox as NSString).appendingPathComponent("\(neverClaimed).json")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: neverClaimed) == .absent)

    let claimed = UUID().uuidString
    write(inbox, "\(claimed).json")
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .unclaimed)
    // Dylib claims it.
    try FileManager.default.moveItem(
      atPath: (inbox as NSString).appendingPathComponent("\(claimed).json"),
      toPath: (inbox as NSString).appendingPathComponent("\(claimed).processing.99")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .claimed)
    // Dylib dies; a later scan or relaunch clears the orphaned claim.
    try FileManager.default.removeItem(
      atPath: (inbox as NSString).appendingPathComponent("\(claimed).processing.99")
    )
    #expect(client.requestQueueState(inboxDir: inbox, id: claimed) == .absent)
  }

}
