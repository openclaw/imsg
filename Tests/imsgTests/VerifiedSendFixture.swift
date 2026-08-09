import Foundation

@testable import IMsgCore

func resolvedSentMessageFixture(
  _ store: MessageStore,
  _ options: MessageSendOptions,
  _ chatID: Int64?,
  _ sentAt: Date
) async throws -> Message? {
  _ = store
  _ = sentAt
  return Message(
    rowID: 42,
    chatID: chatID ?? 0,
    sender: "me@icloud.com",
    text: options.text,
    date: Date(),
    isFromMe: true,
    service: options.service == .sms ? "SMS" : "iMessage",
    handleID: nil,
    attachmentsCount: options.attachmentPath.isEmpty ? 0 : 1,
    guid: "verified-guid"
  )
}
