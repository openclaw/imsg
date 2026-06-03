import Testing

@testable import IMsgCore

#if os(macOS)
  @preconcurrency import Contacts
#endif

@Test
func noOpContactResolverReturnsNoMatches() {
  let resolver = NoOpContactResolver()
  #expect(resolver.contactsUnavailable == false)
  #expect(resolver.displayName(for: "+15551234567") == nil)
  #expect(resolver.displayNames(for: ["+15551234567"]).isEmpty)
  #expect(resolver.searchByName("John").isEmpty)
}

@Test
func noOpContactResolverCanRepresentUnavailableContacts() {
  let resolver = NoOpContactResolver(contactsUnavailable: true)
  #expect(resolver.contactsUnavailable == true)
}

#if os(macOS)
  private actor ContactAccessSpy {
    private var requestCount = 0

    func request(_ store: CNContactStore) async -> Bool {
      _ = store
      requestCount += 1
      return false
    }

    func count() -> Int {
      requestCount
    }
  }

  @Test
  func contactResolverSkipsPromptWhenContactsAreUndeterminedAndPolicyAllowsFailOpen() async {
    let spy = ContactAccessSpy()
    let resolver = await ContactResolver.create(
      accessPolicy: .skipIfNotDetermined,
      store: CNContactStore(),
      authorizationStatus: .notDetermined,
      requestAccess: { store in await spy.request(store) }
    )

    #expect(resolver.contactsUnavailable == true)
    #expect(await spy.count() == 0)
  }

  @Test
  func contactResolverStillRequestsAccessByDefaultWhenContactsAreUndetermined() async {
    let spy = ContactAccessSpy()
    let resolver = await ContactResolver.create(
      store: CNContactStore(),
      authorizationStatus: .notDetermined,
      requestAccess: { store in await spy.request(store) }
    )

    #expect(resolver.contactsUnavailable == true)
    #expect(await spy.count() == 1)
  }
#endif
