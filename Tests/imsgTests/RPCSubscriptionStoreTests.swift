import Testing

@testable import imsg

@Test
func subscriptionStoreRejectsLimitsAndClosureWithoutConsumingIDs() async {
  let store = SubscriptionStore(limit: 1)

  let first: SubscriptionStore.Reservation
  switch await store.reserve() {
  case .reserved(let reservation):
    first = reservation
  case .closed, .limitReached:
    Issue.record("first reservation should succeed")
    return
  }
  #expect(first.id == 1)
  #expect(await store.nextIDForTesting == 2)

  #expect(await store.reserve() == .limitReached)
  #expect(await store.nextIDForTesting == 2)

  await store.cancelAll()
  #expect(await store.count == 0)
  #expect(await store.reserve() == .closed)
  #expect(await store.nextIDForTesting == 2)
}
