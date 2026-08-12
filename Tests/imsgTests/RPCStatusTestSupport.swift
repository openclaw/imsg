import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

final class RPCStatusInvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

func rpcStatusBridgeSnapshot(
  selectors: [String: Bool] = fullRPCStatusBridgeSelectors(),
  registryAvailable: Bool = true,
  rpcMethods: [String]? = nil
) -> [String: Any] {
  var result: [String: Any] = [
    "bridge_version": 2,
    "v2_ready": true,
    "registry_available": registryAvailable,
    "typing_available": true,
    "read_available": true,
    "selectors": selectors,
  ]
  if let rpcMethods { result["rpc_methods"] = rpcMethods }
  return result
}

func fullRPCStatusBridgeSelectors() -> [String: Bool] {
  [
    "sendMessage": true,
    "clientMessageGuid": true,
    "clientMessageGuidReservation": true,
    "sendAttachment": true,
    "sendMultipart": true,
    "sendReaction": true,
    "stickerSend": true,
    "pollPayloadMessage": true,
    "pollVoteMessage": true,
    "typing": true,
    "read": true,
    "createChat": true,
    "markChatUnread": true,
    "deleteMessage": true,
    "notifyAnyways": true,
    "setDisplayName": true,
    "updateGroupPhoto": true,
    "addParticipant": true,
    "removeParticipant": true,
    "leaveChat": true,
    "checkIMessageAvailability": true,
    "editMessageItem": true,
    "retractMessagePart": true,
    "deleteChat": true,
    "namePhotoShouldOffer": true,
    "namePhotoShare": true,
  ]
}

func rpcStatusResult(_ output: TestRPCOutput, at index: Int = 0) throws -> [String: Any] {
  guard output.responses.indices.contains(index) else {
    Issue.record("missing RPC response at index \(index); got \(output.responses.count)")
    return [:]
  }
  return try #require(output.responses[index]["result"] as? [String: Any])
}

func rpcStatusMethods(_ snapshot: [String: Any]) -> Set<String> {
  Set(snapshot["methods"] as? [String] ?? [])
}

func makeUnavailableRPCStatusServer(
  output: TestRPCOutput,
  bridgeReady: Bool = false,
  sendMessage: @escaping (MessageSendOptions) throws -> Void = { _ in },
  invokeBridge: @escaping BridgeInvoker = { _, _ in [:] }
) -> RPCServer {
  RPCServer(
    databasePath: "/tmp/imsg-rpc-status-missing-\(UUID().uuidString)/chat.db",
    verbose: false,
    output: output,
    storeFactory: { _ in throw NSError(domain: "RPCStatusTests", code: 1) },
    sendMessage: sendMessage,
    invokeBridge: invokeBridge,
    isBridgeReady: { bridgeReady }
  )
}
