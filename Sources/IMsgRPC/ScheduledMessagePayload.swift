import Foundation
import IMsgCore

package struct ScheduledMessagePayload: Codable {
  let id: Int64
  let guid: String
  let chatID: Int64
  let chatIdentifier: String
  let chatGUID: String
  let chatName: String
  let text: String
  let service: String
  let scheduledAt: String
  let scheduleType: Int
  let scheduleState: Int

  package init(_ message: ScheduledMessage) {
    self.id = message.rowID
    self.guid = message.guid
    self.chatID = message.chatID
    self.chatIdentifier = message.chatIdentifier
    self.chatGUID = message.chatGUID
    self.chatName = message.chatName
    self.text = message.text
    self.service = message.service
    self.scheduledAt = CLIISO8601.format(message.scheduledAt)
    self.scheduleType = message.scheduleType
    self.scheduleState = message.scheduleState
  }

  enum CodingKeys: String, CodingKey {
    case id
    case guid
    case chatID = "chat_id"
    case chatIdentifier = "chat_identifier"
    case chatGUID = "chat_guid"
    case chatName = "chat_name"
    case text
    case service
    case scheduledAt = "scheduled_at"
    case scheduleType = "schedule_type"
    case scheduleState = "schedule_state"
  }
}
