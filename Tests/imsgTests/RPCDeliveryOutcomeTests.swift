import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func makeDeliveryRuntimeServer(
  output: TestRPCOutput,
  probe: MutationProbe,
  failingName: String,
  disposition: DeliveryDisposition
) throws -> RPCServer {
  let store = try CommandTestDatabase.makeStoreForRPC()
  return RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      let name = params["newName"] as? String ?? ""
      if action == .setDisplayName {
        await probe.invoke(name)
        if name == failingName {
          throw DeliveryFailure(
            disposition: disposition,
            transport: .bridgeV2,
            operation: action.rawValue,
            detail: "The bridge claim is still owned by Messages."
          )
        }
      }
      return [:]
    }
  )
}

@Test(.timeLimit(.minutes(1)))
func rpcStillInFlightPoisonsQueuedAndFutureMutationsButNotReadOrControl() async throws {
  let firstGate = RuntimeGate()
  let probe = MutationProbe(gates: ["first": firstGate])
  let output = TestRPCOutput()
  let server = try makeDeliveryRuntimeServer(
    output: output,
    probe: probe,
    failingName: "first",
    disposition: .stillInFlight
  )
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "first", name: "first"))
  await probe.waitForStarts(1)
  input.yield(renameRequest(id: "queued", name: "queued"))
  input.yield(#"{"jsonrpc":"2.0","id":"read","method":"chats.list","params":{"limit":1}}"#)
  input.yield(
    #"{"jsonrpc":"2.0","id":"control","method":"watch.unsubscribe","params":{"subscription":999}}"#
  )

  await output.waitForOutputCount(2)
  #expect(output.responses.contains { $0["id"] as? String == "read" })
  #expect(output.responses.contains { $0["id"] as? String == "control" })

  await firstGate.open()
  await output.waitForOutputCount(4)
  input.yield(renameRequest(id: "future", name: "future"))
  input.yield(
    #"{"jsonrpc":"2.0","method":"group.rename","params":{"chat_id":1,"name":"silent"}}"#
  )
  await output.waitForOutputCount(5)
  input.finish()
  try await run.value

  #expect(await probe.snapshot().starts == ["first"])
  let errorsByID = Dictionary(
    uniqueKeysWithValues: output.errors.compactMap { envelope -> (String, [String: Any])? in
      guard
        let id = envelope["id"] as? String,
        let error = envelope["error"] as? [String: Any]
      else { return nil }
      return (id, error)
    })
  #expect(errorsByID["first"]?["code"] as? Int == -32001)
  #expect(errorsByID["queued"]?["code"] as? Int == -32004)
  #expect(errorsByID["future"]?["code"] as? Int == -32004)
  let firstData = errorsByID["first"]?["data"] as? [String: Any]
  #expect(firstData?["retry_safe"] as? Bool == false)
  #expect(firstData?["disposition"] as? String == "still_in_flight")
  #expect(firstData?["transport"] as? String == "bridge_v2")
  #expect(firstData?["operation"] as? String == "set-display-name")
  #expect(!String(describing: errorsByID).contains("silent"))
}

@Test(.timeLimit(.minutes(1)))
func rpcMayHaveCompletedDoesNotPoisonFollowingMutation() async throws {
  let firstGate = RuntimeGate()
  let probe = MutationProbe(gates: ["uncertain": firstGate])
  let output = TestRPCOutput()
  let server = try makeDeliveryRuntimeServer(
    output: output,
    probe: probe,
    failingName: "uncertain",
    disposition: .mayHaveCompleted
  )
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "uncertain", name: "uncertain"))
  await probe.waitForStarts(1)
  input.yield(renameRequest(id: "second", name: "second"))
  await firstGate.open()
  await probe.waitForStarts(2)
  input.finish()
  try await run.value

  #expect(await probe.snapshot().starts == ["uncertain", "second"])
  #expect(output.errors.count == 1)
  let error = output.errors.first?["error"] as? [String: Any]
  let data = error?["data"] as? [String: Any]
  #expect(error?["code"] as? Int == -32001)
  #expect(data?["disposition"] as? String == "may_have_completed")
  #expect(output.responses.contains { $0["id"] as? String == "second" })
}

@Test(.timeLimit(.minutes(1)))
func newRPCServerProcessStartsWithUnpoisonedMutationLane() async throws {
  let output = TestRPCOutput()
  let probe = MutationProbe()
  let server = try makeRuntimeServer(output: output, probe: probe)
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(renameRequest(id: "fresh", name: "fresh"))
  input.finish()
  try await run.value

  #expect(await probe.snapshot().starts == ["fresh"])
  #expect(output.responses.first?["id"] as? String == "fresh")
}

@Test(.timeLimit(.minutes(1)))
func rpcSuccessfulPollWithInFlightCaptionStillPoisonsMutationLane() async throws {
  let captionGate = RuntimeGate()
  let captionProbe = MutationProbe(gates: ["caption": captionGate])
  let output = TestRPCOutput()
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, _ in
      switch action {
      case .sendPoll:
        return ["messageGuid": "poll-guid"]
      case .sendMessage:
        await captionProbe.invoke("caption")
        throw DeliveryFailure(
          disposition: .stillInFlight,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "The caption claim is still owned by Messages."
        )
      default:
        return [:]
      }
    }
  )
  let (lines, input) = makeRuntimeLines()
  let run = Task { try await server.run(lines: lines) }

  input.yield(
    #"{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":1,"question":"Dinner?","options":["Pizza","Sushi"]}}"#
  )
  await captionProbe.waitForStarts(1)
  input.yield(renameRequest(id: "queued", name: "queued"))
  await captionGate.open()
  await output.waitForOutputCount(2)
  input.finish()
  try await run.value

  #expect(output.responses.first?["id"] as? String == "poll")
  #expect(output.errors.first?["id"] as? String == "queued")
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(error?["code"] as? Int == -32004)
}
