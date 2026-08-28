import Testing

@testable import IMsgCore

private func participantTarget(
  guid: String = "iMessage;-;friend@example.com",
  participants: [String] = ["friend@example.com"],
  accountID: String? = "test-account",
  service: String = "iMessage"
) -> DirectParticipantTarget? {
  DirectParticipantTarget(
    chat: ChatInfo(
      id: 1, identifier: "friend@example.com", guid: guid, name: "", service: service,
      accountID: accountID),
    participants: participants)
}

@Test
func directParticipantTargetRequiresVerifiedDirectMembershipAndAccount() {
  #expect(participantTarget()?.recipient == "friend@example.com")
  #expect(participantTarget()?.accountID == "test-account")
  #expect(participantTarget()?.service == .imessage)
  #expect(participantTarget(guid: "any;-;friend@example.com") != nil)
  #expect(participantTarget(guid: "iMessage;+;friend@example.com") == nil)
  #expect(participantTarget(guid: "iMessage;-;different@example.com") == nil)
  #expect(participantTarget(guid: "SMS;-;friend@example.com") == nil)
  #expect(participantTarget(participants: []) == nil)
  #expect(participantTarget(participants: ["other@example.com"]) == nil)
  #expect(participantTarget(participants: ["friend@example.com", "other@example.com"]) == nil)
  #expect(participantTarget(accountID: nil) == nil)
  #expect(participantTarget(accountID: "  ") == nil)
  #expect(participantTarget(service: "RCS") == nil)
}

@Test
func directParticipantTargetIsBoundToOriginalChat() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, arguments in captured = arguments })
  let target = try #require(participantTarget())
  try sender.send(
    MessageSendOptions(
      recipient: "", text: "hello", chatGUID: target.chatGUID,
      directParticipantTarget: target))
  #expect(Array(captured[7...]) == ["test-account", "friend@example.com", "imessage"])
  try sender.send(
    MessageSendOptions(
      recipient: "", text: "hello", chatGUID: "iMessage;+;group",
      directParticipantTarget: target))
  #expect(Array(captured[7...]) == ["", "", ""])
}
