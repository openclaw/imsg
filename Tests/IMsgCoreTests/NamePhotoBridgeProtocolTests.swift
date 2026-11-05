import Testing

@testable import IMsgCore

@Suite("Name & Photo bridge protocol")
struct NamePhotoBridgeProtocolTests {
  @Test
  func actionsMatchInjectedHelperVocabulary() {
    #expect(
      BridgeAction.shouldOfferNicknameSharing.rawValue == "should-offer-nickname-sharing"
    )
    #expect(BridgeAction.shareNickname.rawValue == "share-nickname")
    #expect(BridgeAction.setPersonalNickname.rawValue == "set-personal-nickname")
    #expect(BridgeAction.setPersonalNickname.isMutation)
  }

  @Test
  func shareUsesMutationTimeoutWhileInspectionStaysShort() {
    #expect(
      IMsgBridgeProtocol.defaultResponseTimeout(for: .shareNickname)
        == IMsgBridgeProtocol.defaultSendResponseTimeout
    )
    // The helper waits up to ten seconds for imagent's echo before answering.
    #expect(
      IMsgBridgeProtocol.defaultResponseTimeout(for: .setPersonalNickname)
        == IMsgBridgeProtocol.defaultSendResponseTimeout
    )
    #expect(
      IMsgBridgeProtocol.defaultResponseTimeout(for: .shouldOfferNicknameSharing)
        == IMsgBridgeProtocol.defaultResponseTimeout
    )
  }
}
