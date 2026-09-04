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
    guard !options.text.isEmpty else { return nil }

    let lowerBound = sentAt.addingTimeInterval(-2)
    let deadline = Date().addingTimeInterval(8)
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
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
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

    return try store.latestSentMessage(
      matchingText: options.text,
      chatID: verificationChatID,
      since: date
    )
  }

  static func verificationChatID(store: MessageStore, options: MessageSendOptions) throws -> Int64?
  {
    let target = options.chatGUID.isEmpty ? options.chatIdentifier : options.chatGUID
    if !target.isEmpty { return try store.chatInfo(matchingTarget: target)?.id }
    return try ChatTargetResolver.existingDirectChat(
      store: store, recipient: options.recipient, service: options.service)?.id
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
    guard !options.text.isEmpty else { return nil }
    throw DeliveryFailure(
      disposition: .mayHaveCompleted,
      transport: .appleScript,
      operation: "send",
      detail:
        "Messages automation returned success, but no matching outgoing text row was observed within 8 seconds."
    )
  }
}
