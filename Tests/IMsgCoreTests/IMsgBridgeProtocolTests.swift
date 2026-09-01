import Foundation
import Testing

@testable import IMsgCore

@Suite("IMsgBridgeProtocol")
struct IMsgBridgeProtocolTests {
  @Test
  func actionRawValuesMatchDylibVocabulary() {
    #expect(BridgeAction.sendMessage.rawValue == "send-message")
    #expect(BridgeAction.sendSticker.rawValue == "send-sticker")
    #expect(BridgeAction.sendRichLink.rawValue == "send-rich-link")
    #expect(BridgeAction.sendPoll.rawValue == "send-poll")
    #expect(BridgeAction.sendPollUnvote.rawValue == "send-poll-unvote")
    #expect(BridgeAction.sendReaction.rawValue == "send-reaction")
    #expect(BridgeAction.editMessage.rawValue == "edit-message")
    #expect(BridgeAction.unsendMessage.rawValue == "unsend-message")
    #expect(BridgeAction.createChat.rawValue == "create-chat")
    #expect(BridgeAction.searchMessages.rawValue == "search-messages")
    #expect(BridgeAction.checkImessageAvailability.rawValue == "check-imessage-availability")
    // Legacy compat: the integer-id v1 protocol still uses these names.
    #expect(BridgeAction.typing.rawValue == "typing")
    #expect(BridgeAction.read.rawValue == "read")
    #expect(BridgeAction.listChats.rawValue == "list_chats")
  }

  @Test
  func reactionKindMapsToStableAssociatedTypes() {
    #expect(BridgeReactionKind.love.associatedMessageType == 2000)
    #expect(BridgeReactionKind.like.associatedMessageType == 2001)
    #expect(BridgeReactionKind.dislike.associatedMessageType == 2002)
    #expect(BridgeReactionKind.laugh.associatedMessageType == 2003)
    #expect(BridgeReactionKind.emphasize.associatedMessageType == 2004)
    #expect(BridgeReactionKind.question.associatedMessageType == 2005)
    // Removal kinds are exactly +1000.
    for kind in BridgeReactionKind.allCases where !kind.rawValue.hasPrefix("remove-") {
      let removeName = "remove-\(kind.rawValue)"
      let remove = BridgeReactionKind(rawValue: removeName)
      #expect(remove != nil, "missing remove case for \(kind.rawValue)")
      #expect(remove?.associatedMessageType == kind.associatedMessageType + 1000)
    }
  }

  @Test
  func parseAcceptsV2Envelope() throws {
    let raw: [String: Any] = [
      "v": 2,
      "id": "abc-123",
      "success": true,
      "data": ["messageGuid": "M-1"],
      "timestamp": "2026-05-04T12:00:00Z",
    ]
    let response = try BridgeResponse.parse(raw)
    #expect(response.id == "abc-123")
    #expect(response.success == true)
    #expect(response.error == nil)
    #expect(response.data["messageGuid"] as? String == "M-1")
  }

  @Test
  func parseAcceptsLegacyEnvelopeWithoutDataKey() throws {
    let raw: [String: Any] = [
      "id": 42,
      "success": true,
      "handle": "+15551234567",
      "marked_as_read": true,
      "timestamp": "2026-05-04T12:00:00Z",
    ]
    let response = try BridgeResponse.parse(raw)
    #expect(response.id == "42")
    #expect(response.success == true)
    #expect(response.data["handle"] as? String == "+15551234567")
    #expect(response.data["marked_as_read"] as? Bool == true)
    #expect(response.data["timestamp"] == nil, "envelope keys should be stripped")
  }

  @Test
  func parsePropagatesError() throws {
    let raw: [String: Any] = [
      "v": 2,
      "id": "x",
      "success": false,
      "error": "Chat not found",
    ]
    let response = try BridgeResponse.parse(raw)
    #expect(response.success == false)
    #expect(response.error == "Chat not found")
  }

  @Test
  func parsePropagatesAuthoritativeDeliveryDisposition() throws {
    let raw: [String: Any] = [
      "v": 2,
      "id": "duplicate",
      "success": false,
      "error": "tracked GUID is already reserved",
      "delivery_disposition": "not_started",
    ]
    let response = try BridgeResponse.parse(raw)
    #expect(response.deliveryDisposition == .notStarted)
    #expect(response.data["delivery_disposition"] == nil)
  }

  @Test
  func bridgeProtocolUsesLongerDefaultForSendActions() {
    #expect(IMsgBridgeProtocol.defaultResponseTimeout == 10.0)
    #expect(IMsgBridgeProtocol.defaultSendResponseTimeout == 150.0)

    for action in [
      BridgeAction.sendMessage,
      .sendRichLink,
      .sendMultipart,
      .sendAttachment,
      .sendSticker,
      .sendPoll,
      .sendPollVote,
      .sendPollUnvote,
      .sendReaction,
      .createChat,
    ] {
      #expect(
        IMsgBridgeProtocol.defaultResponseTimeout(for: action)
          == IMsgBridgeProtocol.defaultSendResponseTimeout
      )
    }
  }

  @Test
  func bridgeProtocolKeepsShortDefaultForNonSendActions() {
    for action in [
      BridgeAction.status,
      .typing,
      .read,
      .editMessage,
      .unsendMessage,
      .deleteMessage,
      .notifyAnyways,
    ] {
      #expect(
        IMsgBridgeProtocol.defaultResponseTimeout(for: action)
          == IMsgBridgeProtocol.defaultResponseTimeout
      )
    }
  }

  @Test
  func bridgeClientKeepsExplicitTimeoutInvokeSignature() {
    let explicitTimeoutInvoke:
      (BridgeAction, [String: Any], TimeInterval) async throws -> [String: Any] =
        IMsgBridgeClient.shared.invoke
    _ = explicitTimeoutInvoke
  }

  @Test
  func messagesLauncherKeepsLegacyCommandSignatureAndAllowsExplicitTimeout() {
    let defaultTimeoutSend: (String, [String: Any]) async throws -> [String: Any] =
      MessagesLauncher.shared.sendCommand
    let explicitTimeoutSend: (String, [String: Any], TimeInterval) async throws -> [String: Any] =
      MessagesLauncher.shared.sendCommand
    _ = defaultTimeoutSend
    _ = explicitTimeoutSend
  }
}

// A wedged helper keeps Messages.app alive and the dylib mapped, so `status`
// cannot infer liveness from either. Only a published request that never gets
// a reply establishes that the bridge stopped serving.
@Test
func aPublishedRequestWithNoReplyIsTreatedAsUnresponsive() {
  #expect(IMsgBridgeError.timeout(action: "status").indicatesUnresponsiveBridge)
}

@Test
func aReplyFromBridgeIsNotTreatedAsUnresponsive() {
  // An older helper that does not implement an action still serves real
  // commands; reporting it as dead would send operators to the wrong repair.
  #expect(!IMsgBridgeError.dylibReturnedError("unknown action").indicatesUnresponsiveBridge)
  #expect(!IMsgBridgeError.malformedResponse("non-object body").indicatesUnresponsiveBridge)
  #expect(!IMsgBridgeError.ioError("/tmp traverses a symlink").indicatesUnresponsiveBridge)
}

// `prepublicationError` reports launch, queue-write, and cancellation failures
// as .bridgeNotReady before any request is published. No reply was expected, so
// treating it as a dead bridge would flip the capability flags and send the
// operator to re-inject a bridge that was never probed.
@Test
func aPrepublicationFailureIsNotTreatedAsUnresponsive() {
  #expect(!IMsgBridgeError.bridgeNotReady("launch failed").indicatesUnresponsiveBridge)
}
