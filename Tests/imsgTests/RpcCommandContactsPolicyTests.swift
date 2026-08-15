import Foundation
import IMsgCore
import Testing

@testable import imsg

@Suite("Shared Contacts stdin policy")
struct ContactsAccessPolicyStdinTests {
  @Test("headless stdin uses skipIfNotDetermined")
  func headlessSkipsUndetermined() {
    #expect(ContactsAccessPolicy.forStdin(isTTY: false) == .skipIfNotDetermined)
  }

  @Test("interactive stdin keeps requestIfNeeded")
  func interactiveRequestsIfNeeded() {
    #expect(ContactsAccessPolicy.forStdin(isTTY: true) == .requestIfNeeded)
  }
}

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

@Suite("WatchCommand Contacts policy")
struct WatchCommandContactsPolicyTests {
  @Test("watch factory uses skipIfNotDetermined when stdin is not a TTY")
  func headlessFactorySkipsUndetermined() {
    #expect(WatchCommand.contactsAccessPolicy(stdinIsTTY: false) == .skipIfNotDetermined)
  }

  @Test("watch factory keeps requestIfNeeded on interactive stdin")
  func interactiveFactoryRequestsIfNeeded() {
    #expect(WatchCommand.contactsAccessPolicy(stdinIsTTY: true) == .requestIfNeeded)
  }
}

@Suite("SearchCommand Contacts policy")
struct SearchCommandContactsPolicyTests {
  @Test("search factory uses skipIfNotDetermined when stdin is not a TTY")
  func headlessFactorySkipsUndetermined() {
    #expect(SearchCommand.contactsAccessPolicy(stdinIsTTY: false) == .skipIfNotDetermined)
  }

  @Test("search factory keeps requestIfNeeded on interactive stdin")
  func interactiveFactoryRequestsIfNeeded() {
    #expect(SearchCommand.contactsAccessPolicy(stdinIsTTY: true) == .requestIfNeeded)
  }
}
