import Foundation
import Testing

@testable import IMsgCore

/// A v2 request that vanishes from the inbox without a reply can never be
/// answered: `MessagesLauncher` wipes both queue directories when it relaunches
/// Messages.app with the dylib. These cover the three on-disk shapes the poll
/// loop distinguishes so a live request is never mistaken for a discarded one.
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

  private var client: IMsgBridgeClient {
    IMsgBridgeClient(launcher: MessagesLauncher.shared)
  }

  @Test
  func unclaimedRequestCountsAsQueued() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    FileManager.default.createFile(
      atPath: (inbox as NSString).appendingPathComponent("\(id).json"),
      contents: Data("{}".utf8)
    )

    #expect(client.requestStillQueued(inboxDir: inbox, id: id) == true)
  }

  @Test
  func claimedRequestCountsAsQueued() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    let id = UUID().uuidString
    // The dylib claims a request by renaming it to `<id>.processing.<pid>`
    // (see processV2InboxFile); that is still in flight, not discarded.
    FileManager.default.createFile(
      atPath: (inbox as NSString).appendingPathComponent("\(id).processing.4242"),
      contents: Data("{}".utf8)
    )

    #expect(client.requestStillQueued(inboxDir: inbox, id: id) == true)
  }

  @Test
  func missingRequestIsNotQueued() throws {
    let inbox = try makeInbox()
    defer { try? FileManager.default.removeItem(atPath: inbox) }
    // An unrelated request must not keep ours alive.
    FileManager.default.createFile(
      atPath: (inbox as NSString).appendingPathComponent("\(UUID().uuidString).json"),
      contents: Data("{}".utf8)
    )

    #expect(client.requestStillQueued(inboxDir: inbox, id: UUID().uuidString) == false)
  }

  @Test
  func unreadableInboxFailsSafeAsQueued() {
    // Cannot enumerate: keep waiting rather than aborting a live request.
    #expect(
      client.requestStillQueued(
        inboxDir: "/nonexistent/imsg-queue-tests", id: UUID().uuidString
      ) == true
    )
  }
}
