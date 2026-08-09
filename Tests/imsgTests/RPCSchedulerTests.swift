import Foundation
import Testing

@testable import imsg

@Test(.timeLimit(.minutes(1)))
func rpcSchedulerCancellationAccountingDropsQueuedReadExactlyOnce() async throws {
  let readGate = RuntimeGate()
  let readProbe = MutationProbe(gates: ["read": readGate])
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(
    output: output,
    probe: MutationProbe(),
    readProbe: readProbe
  )
  let scheduler = RPCScheduler(server: server, readLimit: 1)
  let request =
    #"{"jsonrpc":"2.0","id":"read","method":"handles.check","params":{"address":"+123"}}"#

  await scheduler.submit(request)
  await scheduler.submit(request.replacingOccurrences(of: #""read""#, with: #""queued""#))
  await readProbe.waitForStarts(1)
  #expect(await scheduler.outstandingCountForTesting == 2)

  await scheduler.stopAdmissionAndCancelReadControl()
  await scheduler.stopAdmissionAndCancelReadControl()
  #expect(await scheduler.outstandingCountForTesting == 1)

  let drain = Task { await scheduler.waitUntilDrained() }
  await readGate.open()
  await drain.value

  #expect(await scheduler.outstandingCountForTesting == 0)
  #expect(output.responses.count == 1)
  #expect(output.responses.first?["id"] as? String == "read")
}
