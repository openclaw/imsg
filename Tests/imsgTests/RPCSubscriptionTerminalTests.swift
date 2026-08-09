import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(.timeLimit(.minutes(1)))
func rpcWatchOverflowFollowsBufferedMessagesAndReturnsResumeCursor() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let messages = (1...3).map { rowID in
    Message(
      rowID: Int64(rowID),
      chatID: 1,
      sender: "+123",
      text: "message-\(rowID)",
      date: Date(),
      isFromMe: false,
      service: "iMessage",
      handleID: 1,
      attachmentsCount: 0
    )
  }
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    watchStreamProvider: { _, _, _, configuration, _ in
      AsyncThrowingStream(bufferingPolicy: .bufferingOldest(configuration.bufferLimit)) {
        continuation in
        var resumeAfterRowID: Int64 = 0
        for message in messages {
          switch continuation.yield(message) {
          case .enqueued:
            resumeAfterRowID = message.rowID
          case .dropped:
            continuation.finish(
              throwing: MessageWatcherOverflowError(resumeAfterRowID: resumeAfterRowID)
            )
            return
          case .terminated:
            return
          @unknown default:
            return
          }
        }
      }
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"buffer_limit":2}}"#
  )
  await output.waitForOutputCount(4)
  await server.subscriptions.waitUntilEmpty()

  let result = output.outputs[0]["result"] as? [String: Any]
  #expect(result?["buffer_limit"] as? Int == 2)
  #expect(output.outputs[1]["method"] as? String == "message")
  #expect(output.outputs[2]["method"] as? String == "message")
  #expect(output.outputs[3]["method"] as? String == "watch.overflow")
  let overflow = output.outputs[3]["params"] as? [String: Any]
  #expect(overflow?["resume_after_rowid"] as? Int64 == 2)
  #expect(overflow?["reason"] as? String == "buffer_limit_exceeded")
  #expect(overflow?["terminal"] as? Bool == true)
  #expect(output.notifications.allSatisfy { $0["method"] as? String != "error" })
}

@Test(.timeLimit(.minutes(1)))
func rpcTerminalSubscriptionStatesRemoveOwnership() async throws {
  struct ExpectedFailure: Error {}

  for terminal in ["natural", "failed", "overflow"] {
    let store = try CommandTestDatabase.makeStoreForRPC()
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      watchStreamProvider: { _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          switch terminal {
          case "failed":
            continuation.finish(throwing: ExpectedFailure())
          case "overflow":
            continuation.finish(throwing: MessageWatcherOverflowError(resumeAfterRowID: 42))
          default:
            continuation.finish()
          }
        }
      }
    )

    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"since_rowid":999}}"#
    )
    if terminal == "natural" {
      await output.waitForOutputCount(1)
    } else {
      await output.waitForOutputCount(2)
    }
    await server.subscriptions.waitUntilEmpty()
    #expect(await server.subscriptions.count == 0)
    if terminal == "failed" {
      #expect(output.notifications.last?["method"] as? String == "error")
    } else if terminal == "overflow" {
      let notification = output.notifications.last
      #expect(notification?["method"] as? String == "watch.overflow")
      let params = notification?["params"] as? [String: Any]
      #expect(params?["resume_after_rowid"] as? Int64 == 42)
      #expect(params?["terminal"] as? Bool == true)
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func rpcWriterKeepsConcurrentOutputsAsValidJSONLines() async throws {
  let writer = RPCWriter()
  let (captured, _) = await StdoutCapture.capture {
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          writer.sendResponse(id: index, result: ["value": index])
        }
      }
    }
    writer.flush()
  }

  let lines = captured.split(separator: "\n")
  #expect(lines.count == 64)
  for line in lines {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    #expect(object is [String: Any])
  }
}
