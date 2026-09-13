import Foundation
import Testing

@testable import IMsgCore

extension IMsgBridgeClientQueueTests {
  @Test
  func unclaimedTimeoutIsReclaimedAsNotStarted() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }

    let failure = try await deliveryFailure {
      try await harness.client().invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .notStarted)
    #expect(failure.retrySafe)
    #expect(!FileManager.default.fileExists(atPath: harness.requestPath))
  }

  @Test
  func launchFailureBeforePublicationIsNotStarted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { false },
      launch: { throw MessagesLauncherError.launchFailed("injected launch failure") }
    )
    let client = IMsgBridgeClient(testing: launcher)

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .notStarted)
    #expect(failure.retrySafe)
    #expect(!FileManager.default.fileExists(atPath: launcher.bridgeInboxDirectory))
  }

  @Test
  func claimedTimeoutStaysInFlightAndPreservesClaim() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let claimPath = harness.claimPath(pid: 4242)
    let client = harness.client { publication in
      try? FileManager.default.moveItem(
        atPath: publication.requestPath,
        toPath: claimPath
      )
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .stillInFlight)
    #expect(FileManager.default.fileExists(atPath: claimPath))
  }

  @Test
  func vanishedPublishedRequestIsOutcomeUnknown() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client { publication in
      try? FileManager.default.removeItem(atPath: publication.requestPath)
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .mayHaveCompleted)
    #expect(!failure.retrySafe)
  }

  @Test
  func helperDuplicateRejectionIsAuthoritativeNotStarted() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client { publication in
      let response: [String: Any] = [
        "v": 2,
        "id": publication.id,
        "success": false,
        "error": "clientMessageGuid is already reserved by another tracked send",
        "delivery_disposition": "not_started",
      ]
      let data = try? JSONSerialization.data(withJSONObject: response)
      try? data?.write(to: URL(fileURLWithPath: publication.responsePath))
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 1)
    }

    #expect(failure.disposition == .notStarted)
    #expect(failure.retrySafe)
  }

  @Test
  func unreadableQueueIsStillInFlight() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client { publication in
      try? FileManager.default.removeItem(atPath: publication.requestPath)
      try? FileManager.default.removeItem(atPath: publication.inboxDirectory)
      FileManager.default.createFile(
        atPath: publication.inboxDirectory,
        contents: Data("not-a-directory".utf8)
      )
    }

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0)
    }

    #expect(failure.disposition == .stillInFlight)
  }

  @Test
  func finalResponseRecheckWinsClassificationRace() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let client = harness.client(classificationObserver: { publication in
      let response: [String: Any] = [
        "v": 2,
        "id": publication.id,
        "success": true,
        "data": ["messageGuid": "won-race"],
      ]
      let data = try? JSONSerialization.data(withJSONObject: response)
      try? data?.write(to: URL(fileURLWithPath: publication.responsePath))
    })

    let result = try await client.invoke(action: .sendMessage, timeout: 0)

    #expect(result["messageGuid"] as? String == "won-race")
  }

  @Test
  func cancellationUsesSameUnclaimedReclaim() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let (publications, continuation) = AsyncStream<Void>.makeStream()
    let client = harness.client(
      pollInterval: .seconds(30),
      publicationObserver: { _ in continuation.yield(()) }
    )
    let task = Task { () -> DeliveryFailure? in
      do {
        _ = try await client.invoke(action: .sendMessage, timeout: 30)
        return nil
      } catch let failure as DeliveryFailure {
        return failure
      } catch {
        Issue.record("expected DeliveryFailure, got \(error)")
        return nil
      }
    }
    for await _ in publications { break }
    task.cancel()

    guard let failure = await task.value else {
      Issue.record("expected typed cancellation delivery failure")
      return
    }
    #expect(failure.disposition == .notStarted)
    #expect(!FileManager.default.fileExists(atPath: harness.requestPath))
  }

  @Test
  func nonLaunchingReadCancellationPropagatesAfterReclaim() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let (publications, continuation) = AsyncStream<Void>.makeStream()
    let client = harness.client(
      pollInterval: .seconds(30),
      publicationObserver: { _ in continuation.yield(()) }
    )
    let task = Task { () -> Bool in
      do {
        _ = try await client.invokeWithoutLaunching(action: .status)
        Issue.record("expected cancellation")
        return false
      } catch is CancellationError {
        return true
      } catch {
        Issue.record("expected CancellationError, got \(error)")
        return false
      }
    }
    for await _ in publications { break }
    task.cancel()

    #expect(await task.value)
    #expect(!FileManager.default.fileExists(atPath: harness.requestPath))
  }

  @Test
  func legacyMutationTimeoutRemainsInFlight() async throws {
    let harness = try BridgeClientHarness()
    defer { harness.remove() }
    let launcher = MessagesLauncher(
      containerPath: harness.root.path,
      readyCheck: { true },
      injectedReadyCheck: { true }
    )
    let client = IMsgBridgeClient(
      testing: launcher,
      useLegacyIPC: true,
      legacyInvoker: { action, _, _ in
        throw MessagesLauncherError.commandTimeout(action.rawValue)
      }
    )

    let failure = try await deliveryFailure {
      try await client.invoke(action: .sendMessage, timeout: 0.01)
    }

    #expect(failure.disposition == .stillInFlight)
    #expect(failure.transport == .bridgeLegacy)
  }

}
