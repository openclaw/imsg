import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(.timeLimit(.minutes(1)))
func rpcUnsubscribeResponseIsFinalAndCancellationIsSilent() async throws {
  let source = ControlledWatchSource()
  let output = TestRPCOutput()
  let server = try makeRuntimeServer(
    output: output,
    probe: MutationProbe(),
    watchSource: source
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#
  )
  await source.waitForStreams(1)
  source.yield(
    Message(
      rowID: 5,
      chatID: 1,
      sender: "+123",
      text: "before unsubscribe",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  )
  await output.waitForOutputCount(2)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unsubscribe","method":"watch.unsubscribe","params":{"subscription":1}}"#
  )
  await source.waitForTerminations(1)
  await server.subscriptions.waitUntilEmpty()

  let outputsAtUnsubscribe = output.outputs.count
  let terminated = source.yield(
    Message(
      rowID: 6,
      chatID: 1,
      sender: "+123",
      text: "after unsubscribe",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  )
  #expect(terminated)
  #expect(output.outputs.count == outputsAtUnsubscribe)
  #expect(output.outputs.last?["id"] as? String == "unsubscribe")
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "error" })
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "watch.overflow" })
}
