import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcCommandUsesFailOpenContactsPolicyAtStartup() {
  // Headless RPC must not await CNContactStore.requestAccess when auth is
  // still undetermined (issue #186). Match chats/history fail-open policy.
  #expect(RpcCommand.startupContactsAccessPolicy == .skipIfNotDetermined)
}
