import Foundation
import IMsgCore

enum TrackedSendVerifier {
  static func verify(
    store: MessageStore, guid: String, chatTarget: String, afterRowID: Int64,
    timeout: TimeInterval = 8,
    now: () -> Date = Date.init,
    wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
  ) async throws {
    let deadline = now().addingTimeInterval(timeout)
    do {
      repeat {
        if Task.isCancelled { break }
        if try store.hasTrackedSendReceipt(
          guid: guid, chatTarget: chatTarget, afterRowID: afterRowID)
        {
          return
        }
        if now() >= deadline { break }
        try await wait()
      } while now() < deadline
    } catch {
      throw failure(
        "The tracked send was acknowledged, but its database receipt could not be verified.")
    }
    throw failure(
      "The tracked send was acknowledged, but the requested GUID was not observed in the target chat. Do not retry this attempt."
    )
  }

  static func failure(_ detail: String) -> DeliveryFailure {
    DeliveryFailure(
      disposition: .mayHaveCompleted, transport: .bridgeV2,
      operation: BridgeAction.sendMessage.rawValue, detail: detail)
  }
}
