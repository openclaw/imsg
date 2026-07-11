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
  }

  @Test
  func shareUsesMutationTimeoutWhileInspectionStaysShort() {
    #expect(
      IMsgBridgeProtocol.defaultResponseTimeout(for: .shareNickname)
        == IMsgBridgeProtocol.defaultSendResponseTimeout
    )
    #expect(
      IMsgBridgeProtocol.defaultResponseTimeout(for: .shouldOfferNicknameSharing)
        == IMsgBridgeProtocol.defaultResponseTimeout
    )
  }
}
