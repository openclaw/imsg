import Foundation
import IMsgCore
import Testing
@testable import imsg

@Suite("RpcCommand Contacts policy")
struct RpcCommandContactsPolicyTests {
  @Test("headless stdin uses skipIfNotDetermined")
  func headlessSkipsUndetermined() {
    #expect(RpcCommand.contactsAccessPolicy(stdinIsTTY: false) == .skipIfNotDetermined)
  }

  @Test("interactive stdin keeps requestIfNeeded")
  func interactiveRequestsIfNeeded() {
    #expect(RpcCommand.contactsAccessPolicy(stdinIsTTY: true) == .requestIfNeeded)
  }
}
