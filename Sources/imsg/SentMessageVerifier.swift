import Foundation
import IMsgCore

enum SentMessageVerifier {
  typealias Resolver = (
    _ store: MessageStore,
    _ options: MessageSendOptions,
    _ chatID: Int64?,
    _ sentAt: Date
  ) async throws -> Message?

  static func resolveSentMessage(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    sentAt: Date
  ) async throws -> Message? {
    try await resolveSentMessage(
      store: store, options: options, chatID: chatID, sentAt: sentAt,
      now: Date.init, wait: { try await Task.sleep(nanoseconds: 100_000_000) })
  }

  static func resolveSentMessage(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    sentAt: Date,
    now: () -> Date,
    wait: () async throws -> Void
  ) async throws -> Message? {
    guard !options.text.isEmpty || !options.attachmentPath.isEmpty else { return nil }

    let lowerBound = sentAt.addingTimeInterval(-2)
    let deadline = now().addingTimeInterval(8)
    repeat {
      if Task.isCancelled { return nil }
      if let message = try resolveSentMessageCandidate(
        store: store,
        options: options,
        chatID: chatID,
        since: lowerBound
      ) {
        return message
      }
      try await wait()
    } while now() < deadline
    return nil
  }

  static func resolveSentMessage(
    store: MessageStore,
    messageGUID: String,
    chatInfo: ChatInfo,
    afterRowID: Int64
  ) async throws -> Message? {
    guard !messageGUID.isEmpty, !chatInfo.guid.isEmpty else { return nil }

    let deadline = Date().addingTimeInterval(8)
    repeat {
      if Task.isCancelled { return nil }
      if let status = try store.messageSendStatus(guid: messageGUID),
        status.rowID > afterRowID,
        try store.messageBelongsToChat(messageGUID: messageGUID, chatGUID: chatInfo.guid)
      {
        return Message(
          rowID: status.rowID,
          chatID: chatInfo.id,
          sender: "",
          text: "",
          date: Date(),
          isFromMe: true,
          service: status.service,
          handleID: nil,
          attachmentsCount: 1,
          guid: status.guid
        )
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return nil
  }

  static func resolveSentMessageCandidate(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    since date: Date
  ) throws -> Message? {
    let verificationChatID = try chatID ?? self.verificationChatID(store: store, options: options)
    guard let verificationChatID else { return nil }
    var chatIDs = [verificationChatID]
    if options.usedDirectParticipantRecovery, let target = options.directParticipantTarget {
      let prefix = target.service == .sms ? "SMS" : "iMessage"
      for guid in [target.chatGUID, "\(prefix);-;\(target.recipient)", "any;-;\(target.recipient)"]
      {
        guard let chat = try store.chatInfo(matchingExactGUID: guid),
          chat.identifier == target.recipient, chat.accountID == target.accountID,
          try store.participants(chatID: chat.id) == [target.recipient]
        else { continue }
        if !chatIDs.contains(chat.id) { chatIDs.append(chat.id) }
      }
    }

    if options.text.isEmpty, !options.attachmentPath.isEmpty {
      return try store.sentAttachmentReceipt(
        matchingPath: options.attachmentPath, chatIDs: chatIDs, since: date,
        service: options.service)
    }
    var receipt: Message?
    for candidateID in chatIDs {
      if let candidate = try store.latestSentMessage(
        matchingText: options.text, chatID: candidateID, since: date, service: options.service)
      {
        if let receipt, receipt.rowID != candidate.rowID { return nil }
        receipt = candidate
      }
    }
    return receipt
  }

  static func verificationChatID(store: MessageStore, options: MessageSendOptions) throws -> Int64?
  {
    let target = options.chatGUID.isEmpty ? options.chatIdentifier : options.chatGUID
    if !target.isEmpty { return try store.chatInfo(matchingTarget: target)?.id }
    if let chat = try ChatTargetResolver.existingDirectChat(
      store: store, recipient: options.recipient, service: options.service)
    {
      return chat.id
    }
    // Messages keeps one "any;-;<handle>" chat per contact and leaves service_name at the
    // service first used there, so an iMessage send can land in an SMS-labelled chat.
    // Receipt matching below still requires the effective send service and outgoing text.
    let recipient = options.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !recipient.isEmpty else { return nil }
    return try store.chatInfo(matchingExactGUID: "any;-;\(recipient)")?.id
  }

  static func throwIfMisroutedChatSend(
    store: MessageStore,
    options: MessageSendOptions,
    sentAt: Date
  ) throws {
    let handles = [options.chatGUID, options.chatIdentifier].filter { !$0.isEmpty }
    guard !handles.isEmpty else { return }
    let lowerBound = sentAt.addingTimeInterval(-2)
    guard
      let rowID = try? store.latestUnjoinedSentMessageRowID(
        matchingTargetHandles: handles,
        since: lowerBound
      )
    else {
      return
    }

    throw DeliveryFailure(
      disposition: .mayHaveCompleted,
      transport: .appleScript,
      operation: "send",
      detail:
        "Messages accepted the chat send but wrote an unjoined empty outgoing row (\(rowID)); delivery to the target chat was not confirmed"
    )
  }

  static func verifyAppleScriptSend(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    sentAt: Date,
    resolve: Resolver
  ) async throws -> Message? {
    let message = try? await resolve(store, options, chatID, sentAt)
    if let message { return message }

    try throwIfMisroutedChatSend(store: store, options: options, sentAt: sentAt)
    guard !options.text.isEmpty || !options.attachmentPath.isEmpty else { return nil }
    let content = options.text.isEmpty ? "attachment" : "text"
    throw DeliveryFailure(
      disposition: .mayHaveCompleted,
      transport: .appleScript,
      operation: "send",
      detail:
        "Messages automation returned success, but no matching outgoing \(content) row was observed within 8 seconds."
    )
  }
}
