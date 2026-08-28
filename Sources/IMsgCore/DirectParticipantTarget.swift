import Foundation

/// A database-verified direct conversation, bound to its original account.
public struct DirectParticipantTarget: Sendable, Equatable {
  public let chatGUID: String
  public let recipient: String
  public let accountID: String
  public let service: MessageService

  public init?(chat: ChatInfo, participants: [String]) {
    let parts = chat.guid.split(separator: ";", omittingEmptySubsequences: false)
    guard
      parts.count == 3, parts[1] == "-", parts[2] == chat.identifier,
      !chat.identifier.isEmpty, participants == [chat.identifier],
      let accountID = chat.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty,
      let service = MessageService(rawValue: chat.service.lowercased()), service != .auto,
      parts[0].lowercased() == chat.service.lowercased() || parts[0] == "any"
    else { return nil }
    self.chatGUID = chat.guid
    self.recipient = chat.identifier
    self.accountID = accountID
    self.service = service
  }
}
