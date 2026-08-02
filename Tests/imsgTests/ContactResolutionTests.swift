import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func contactNameDetectionIgnoresPhonesAndEmails() {
  #expect(ChatTargetResolver.looksLikeContactName("+15551234567") == false)
  #expect(ChatTargetResolver.looksLikeContactName("(555) 123-4567") == false)
  #expect(ChatTargetResolver.looksLikeContactName("user@example.com") == false)
  #expect(ChatTargetResolver.looksLikeContactName("") == false)
}

@Test
func contactNameDetectionAcceptsNames() {
  #expect(ChatTargetResolver.looksLikeContactName("John Smith") == true)
  #expect(ChatTargetResolver.looksLikeContactName("Alice") == true)
}

@Test
func contactNameResolutionPassesThroughUnknownNames() throws {
  let resolver = MockContactResolver()
  let resolved = try ChatTargetResolver.resolveRecipientName("Unknown Person", contacts: resolver)
  #expect(resolved == "Unknown Person")
}

@Test
func contactNameResolutionRejectsNamesWhenContactsAreUnavailable() {
  let resolver = MockContactResolver(contactsUnavailable: true)
  #expect(throws: (any Error).self) {
    try ChatTargetResolver.resolveRecipientName("Unknown Person", contacts: resolver)
  }
}

@Test
func contactNameResolutionReturnsUniqueMatch() throws {
  let resolver = MockContactResolver(
    matches: [ContactMatch(name: "John Smith", handle: "+15551234567")]
  )
  let resolved = try ChatTargetResolver.resolveRecipientName("John", contacts: resolver)
  #expect(resolved == "+15551234567")
}

@Test
func contactNameResolutionRejectsAmbiguousMatches() {
  let resolver = MockContactResolver(
    matches: [
      ContactMatch(name: "John Smith", handle: "+15551234567"),
      ContactMatch(name: "John Doe", handle: "+15557654321"),
    ]
  )
  #expect(throws: (any Error).self) {
    try ChatTargetResolver.resolveRecipientName("John", contacts: resolver)
  }
}

@Test
func encodedChatPayloadIncludesContactName() throws {
  let chat = Chat(
    id: 1,
    identifier: "+15551234567",
    name: "+15551234567",
    service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0)
  )
  let payload = ChatPayload(chat: chat, contactName: "John Smith")
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data)
  let json = try #require(object as? [String: Any])
  #expect(json["contact_name"] as? String == "John Smith")
}

@Test
func messagePayloadIncludesSenderName() throws {
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+15551234567",
    text: "hello",
    date: Date(timeIntervalSince1970: 0),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-1"
  )
  let payload = MessagePayload(message: message, attachments: [], senderName: "John Smith")
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data)
  let json = try #require(object as? [String: Any])
  #expect(json["sender_name"] as? String == "John Smith")
}

@Test
func reactionPayloadIncludesSenderName() throws {
  let reaction = Reaction(
    rowID: 2,
    reactionType: .like,
    sender: "+15551234567",
    isFromMe: false,
    date: Date(timeIntervalSince1970: 0),
    associatedMessageID: 1
  )
  let payload = ReactionPayload(reaction: reaction, senderName: "John Smith")
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data)
  let json = try #require(object as? [String: Any])
  #expect(json["sender_name"] as? String == "John Smith")
}
