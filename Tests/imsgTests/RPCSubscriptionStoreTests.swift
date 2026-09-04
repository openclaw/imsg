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
  #expect(await store.reserve() == .closed)
  #expect(await store.nextIDForTesting == 2)
}

@Test(arguments: [false, true])
func subscriptionCancellationRetainsOwnershipUntilCleanupFinishes(unsubscribe: Bool) async throws {
  let output = TestRPCOutput()
  let server = RPCServer(databasePath: "/unused", verbose: false, output: output)
  let store = server.subscriptions
  guard case .reserved(let reservation) = await store.reserve() else {
    Issue.record("reservation should succeed")
    return
  }
  let cancelled = RuntimeGate()
  let cleanup = RuntimeGate()
  let task = Task {
    await withTaskCancellationHandler {
      await cleanup.wait()
    } onCancel: {
      Task { await cancelled.open() }
    }
  }
  #expect(await store.activate(task, reservation: reservation) == .activated)

  let first = Task {
    if unsubscribe {
      try await server.handleWatchUnsubscribe(id: 1, params: ["subscription": reservation.id])
    } else {
      await store.cancelAll()
    }
  }
  await cancelled.wait()
  #expect(await store.count == 1)
  #expect(output.responses.isEmpty)

  let shutdown = Task { await store.cancelAll() }
  await store.waitUntilClosed()
  #expect(await store.count == 1)
  await cleanup.open()
  try await first.value
  await shutdown.value
  #expect(await store.count == 0)
  #expect(output.responses.count == (unsubscribe ? 1 : 0))
}
