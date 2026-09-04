import Foundation
import IMsgCore

struct ChatTargetInput: Sendable {
  let recipient: String
  let chatID: Int64?
  let chatIdentifier: String
  let chatGUID: String

  var hasChatTarget: Bool {
    chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
  }
}

struct ResolvedChatTarget: Sendable {
  let chatIdentifier: String
  let chatGUID: String

  var preferredIdentifier: String? {
    if !chatGUID.isEmpty { return chatGUID }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    return nil
  }
}

enum ChatTargetResolver {
  static func validateRecipientRequirements(
    input: ChatTargetInput,
    mixedTargetError: Error,
    missingRecipientError: Error
  ) throws {
    if input.hasChatTarget && !input.recipient.isEmpty {
      throw mixedTargetError
    }
    if !input.hasChatTarget && input.recipient.isEmpty {
      throw missingRecipientError
    }
  }

  static func resolveChatTarget(
    input: ChatTargetInput,
    lookupChat: (Int64) async throws -> ChatInfo?,
    unknownChatError: (Int64) -> Error
  ) async throws -> ResolvedChatTarget {
    var resolvedIdentifier = input.chatIdentifier
    var resolvedGUID = input.chatGUID

    if let chatID = input.chatID {
      guard let info = try await lookupChat(chatID) else {
        throw unknownChatError(chatID)
      }
      resolvedIdentifier = info.identifier
      resolvedGUID = info.guid
    }

    return ResolvedChatTarget(
      chatIdentifier: resolvedIdentifier,
      chatGUID: resolvedGUID
    )
  }

  static func directTypingIdentifier(
    recipient: String,
    serviceRaw: String,
    invalidServiceError: (String) -> Error
  ) throws -> String {
    guard let service = MessageService(rawValue: serviceRaw.lowercased()) else {
      throw invalidServiceError(serviceRaw)
    }
    let prefix = service == .sms ? "SMS" : "iMessage"
    return "\(prefix);-;\(recipient)"
  }

  static func directChatCandidates(recipient: String, service: MessageService) -> [String] {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var candidates: [String] = []
    func append(_ value: String) {
      if !candidates.contains(value) {
        candidates.append(value)
      }
    }

    switch service {
    case .sms:
      append("SMS;-;\(trimmed)")
    case .imessage:
      append("iMessage;-;\(trimmed)")
      append("any;-;\(trimmed)")
    case .auto:
      append("iMessage;-;\(trimmed)")
      append("any;-;\(trimmed)")
      append("SMS;-;\(trimmed)")
    }
    append(trimmed)
    return candidates
  }

  static func existingDirectChat(
    store: MessageStore,
    recipient: String,
    service: MessageService,
    includeAnyForSMS: Bool = false
  ) throws -> ChatInfo? {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates = directChatCandidates(recipient: recipient, service: service)
    if includeAnyForSMS, !trimmed.isEmpty {
      candidates = ["SMS;-;\(trimmed)", "any;-;\(trimmed)", "any;+;\(trimmed)"]
    }
    let services = service == .sms ? ["SMS"] : ["iMessage", "iMessageLite"]
    for candidate in candidates {
      let info =
        includeAnyForSMS
        ? try store.chatInfo(matchingExactTarget: candidate, preferredServices: services)
        : try store.chatInfo(matchingTarget: candidate, preferredServices: services)
      // Auto-detected SMS can use a neutral "any" chat with older service metadata.
      if let info, includeAnyForSMS || service == .auto || services.contains(info.service) {
        return info
      }
    }
    return nil
  }

  static func looksLikeContactName(_ recipient: String) -> Bool {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    if trimmed.contains("@") { return false }
    if trimmed.hasPrefix("+") { return false }
    let phoneCharacters = CharacterSet(charactersIn: "0123456789-(). ")
    if trimmed.unicodeScalars.allSatisfy({ phoneCharacters.contains($0) }) {
      return false
    }
    return true
  }

  static func directParticipantTarget(
    store: MessageStore?,
    resolvedTarget: ResolvedChatTarget,
    directChatInfo: ChatInfo?
  ) -> DirectParticipantTarget? {
    guard let store else { return nil }
    let chat =
      directChatInfo
      ?? resolvedTarget.preferredIdentifier.flatMap {
        try? store.chatInfo(matchingExactTarget: $0)
      }
    guard let chat, let participants = try? store.participants(chatID: chat.id) else {
      return nil
    }
    return DirectParticipantTarget(chat: chat, participants: participants)
  }

  static func resolveRecipientName(
    _ recipient: String,
    contacts: any ContactResolving
  ) throws -> String {
    guard looksLikeContactName(recipient) else { return recipient }
    guard !contacts.contactsUnavailable else {
      throw IMsgError.invalidChatTarget(
        "Contacts access is unavailable; specify a phone number or email instead."
      )
    }
    let matches = contacts.searchByName(recipient)
    switch matches.count {
    case 0:
      return recipient
    case 1:
      return matches[0].handle
    default:
      let details =
        matches
        .map { "  \($0.name): \($0.handle)" }
        .joined(separator: "\n")
      throw IMsgError.invalidChatTarget(
        "Multiple contacts match \"\(recipient)\":\n\(details)\nSpecify a phone number or email instead."
      )
    }
  }
}
