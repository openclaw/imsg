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

  private final class ContactTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
      lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
      lock.withLock { value += interval }
    }
  }

  private final class ContactSourceHarness: @unchecked Sendable {
    struct LoadFailure: Error {}

    private let lock = NSLock()
    private var authorizationValue: ContactCatalogAuthorization
    private var recordsValue: [ContactCatalogRecord]
    private var shouldFail = false
    private var observer: (@Sendable () -> Void)?
    private var loads = 0
    private var loadStarted: DispatchSemaphore?
    private var loadRelease: DispatchSemaphore?

    init(
      authorization: ContactCatalogAuthorization = .authorized,
      records: [ContactCatalogRecord] = []
    ) {
      self.authorizationValue = authorization
      self.recordsValue = records
    }

    var source: ContactCatalogSource {
      ContactCatalogSource(
        authorization: { [self] in authorization() },
        load: { [self] in try load() },
        observeChanges: { [self] observer in
          lock.withLock { self.observer = observer }
          return {}
        }
      )
    }

    var loadCount: Int { lock.withLock { loads } }

    func setAuthorization(_ authorization: ContactCatalogAuthorization) {
      lock.withLock { authorizationValue = authorization }
    }

    func setRecords(_ records: [ContactCatalogRecord]) {
      lock.withLock { recordsValue = records }
    }

    func setFailure(_ value: Bool) {
      lock.withLock { shouldFail = value }
    }

    func blockNextLoad(started: DispatchSemaphore, release: DispatchSemaphore) {
      lock.withLock {
        loadStarted = started
        loadRelease = release
      }
    }

    func notify() {
      let callback = lock.withLock { observer }
      callback?()
    }

    private func authorization() -> ContactCatalogAuthorization {
      lock.withLock { authorizationValue }
    }

    private func load() throws -> [ContactCatalogRecord] {
      let state = lock.withLock {
        () -> (Bool, [ContactCatalogRecord], DispatchSemaphore?, DispatchSemaphore?) in
        loads += 1
        let state = (shouldFail, recordsValue, loadStarted, loadRelease)
        loadStarted = nil
        loadRelease = nil
        return state
      }
      state.2?.signal()
      state.3?.wait()
      if state.0 { throw LoadFailure() }
      return state.1
    }
  }

  private func contactRecord(
    name: String,
    phone: String = "+15551234567"
  ) -> ContactCatalogRecord {
    ContactCatalogRecord(name: name, phones: [phone], emails: [])
  }

  @Test
  func contactCatalogRefreshesAfterChangeNotification() {
    let source = ContactSourceHarness(records: [contactRecord(name: "Alice")])
    let resolver = ContactResolver(region: "US", source: source.source, refreshInterval: 60)

    #expect(resolver.displayName(for: "+15551234567") == "Alice")
    source.setRecords([contactRecord(name: "Bob")])
    #expect(resolver.displayName(for: "+15551234567") == "Alice")

    source.notify()
    #expect(resolver.displayName(for: "+15551234567") == "Bob")
    #expect(source.loadCount == 2)
  }

  @Test
  func contactCatalogTTLRefreshesMissedChanges() {
    let clock = ContactTestClock()
    let source = ContactSourceHarness(records: [contactRecord(name: "Alice")])
    let resolver = ContactResolver(
      region: "US",
      source: source.source,
      refreshInterval: 10,
      now: clock.now
    )

    #expect(resolver.displayName(for: "+15551234567") == "Alice")
    source.setRecords([contactRecord(name: "Bob")])
    clock.advance(by: 9)
    #expect(resolver.displayName(for: "+15551234567") == "Alice")
    clock.advance(by: 2)
    #expect(resolver.displayName(for: "+15551234567") == "Bob")
  }

  @Test
  func contactCatalogTracksAuthorizationAndClearsRevokedData() {
    let clock = ContactTestClock()
    let source = ContactSourceHarness(
      authorization: .notDetermined,
      records: [contactRecord(name: "Alice")]
    )
    let resolver = ContactResolver(
      region: "US",
      source: source.source,
      refreshInterval: 10,
      now: clock.now
    )

    #expect(resolver.contactsUnavailable)
    source.setAuthorization(.authorized)
    clock.advance(by: 11)
    #expect(resolver.contactsUnavailable == false)
    #expect(resolver.displayName(for: "+15551234567") == "Alice")

    source.setAuthorization(.unavailable)
    clock.advance(by: 11)
    #expect(resolver.contactsUnavailable)
    source.setAuthorization(.authorized)
    source.setFailure(true)
    clock.advance(by: 11)
    #expect(resolver.displayName(for: "+15551234567") == nil)
    #expect(resolver.contactsUnavailable)
  }

  @Test
  func contactCatalogRetainsLastGoodDataOnTransientLoadFailure() {
    let source = ContactSourceHarness(records: [contactRecord(name: "Alice")])
    let resolver = ContactResolver(region: "US", source: source.source, refreshInterval: 60)

    #expect(resolver.displayName(for: "+15551234567") == "Alice")
    source.setFailure(true)
    source.notify()
    #expect(resolver.displayName(for: "+15551234567") == "Alice")
    #expect(resolver.contactsUnavailable == false)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func contactCatalogCoalescesConcurrentRefreshes(changingSource: Bool) {
    let source = ContactSourceHarness(records: [contactRecord(name: "Alice")])
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let resolver = ContactResolver(region: "US", source: source.source, refreshInterval: 60)
    if changingSource {
      _ = resolver.displayName(for: "+15551234567")
      source.setRecords([contactRecord(name: "Bob")])
      source.setAuthorization(.addressBook)
    }
    source.blockNextLoad(started: started, release: release)
    let entered = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let threads = (0..<8).map { _ in
      group.enter()
      return Thread {
        entered.signal()
        let name = resolver.displayName(for: "+15551234567")
        #expect(name == (changingSource ? "Bob" : "Alice"))
        let names = resolver.displayNames(for: ["+15551234567", "absent@example.test"])
        #expect(names == ["+15551234567": changingSource ? "Bob" : "Alice"])
        group.leave()
      }
    }
    for thread in threads {
      thread.start()
    }

    started.wait()
    for _ in threads { entered.wait() }
    #expect(source.loadCount == (changingSource ? 2 : 1))
    release.signal()
    group.wait()
    #expect(source.loadCount == (changingSource ? 2 : 1))
  }

  @Test
  func contactCatalogBoundsNormalizedRegionSnapshots() {
    let source = ContactSourceHarness(records: [contactRecord(name: "Alice", phone: "07700900000")])
    let resolver = ContactResolver(
      region: "US",
      source: source.source,
      maximumRegionSnapshots: 2
    )

    _ = resolver.searchByName("Alice")
    _ = resolver.resolver(region: "GB").searchByName("Alice")
    _ = resolver.resolver(region: "FR").searchByName("Alice")

    #expect(resolver.cachedRegionCount == 2)
    #expect(source.loadCount == 1)
  }

  @Test
  func contactCatalogKeepsConcurrentRegionalLookupsIndependent() {
    let source = ContactSourceHarness(records: [
      contactRecord(name: "UK contact", phone: "+447700900000"),
      contactRecord(name: "US contact", phone: "+16502530000"),
    ])
    let resolver = ContactResolver(region: "US", source: source.source)
    let british = resolver.resolver(region: "GB")
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      #expect(british.displayName(for: "07700 900000") == "UK contact")
      #expect(resolver.displayName(for: "650 253 0000") == "US contact")
      #expect(british.displayNames(for: ["07700 900000"]) == ["07700 900000": "UK contact"])
      #expect(resolver.displayNames(for: ["650 253 0000"]) == ["650 253 0000": "US contact"])
    }
    #expect(source.loadCount == 1)
  }
#endif
