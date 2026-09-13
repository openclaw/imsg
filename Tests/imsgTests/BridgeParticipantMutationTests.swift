import Foundation
import Testing

@Test
func participantMutationsUseCurrentAndLegacySelectors() throws {
  let source = try injectedHelperSource()
  let addBody = try #require(
    bridgeFunctionBody(named: "handleAddParticipant", in: source))
  let removeBody = try #require(
    bridgeFunctionBody(named: "handleRemoveParticipant", in: source))

  #expect(addBody.contains(#"@"inviteParticipants:reason:""#))
  #expect(addBody.contains(#"@"inviteParticipantsToiMessageChat:reason:""#))
  #expect(removeBody.contains(#"@"removeParticipants:reason:""#))
  #expect(removeBody.contains(#"@"removeParticipantsFromiMessageChat:reason:""#))
}
