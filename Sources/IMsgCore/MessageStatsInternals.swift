struct StatsChatDimension: Sendable, Equatable {
  let id: Int64
  let identifier: String
  let name: String
  let service: String
}

struct StatsMessageRow {
  let message: Message
  let chat: StatsChatDimension
}

struct StatsMessageKey: Hashable {
  let chatID: Int64
  let rowID: Int64
}

struct StatsAttachmentRow {
  let id: Int64
  let chat: StatsChatDimension
  let uti: String
  let mimeType: String
  let totalBytes: Int64
}

struct ChatMessageCount {
  let chat: StatsChatDimension
  var count: Int64
}

struct MediaTypeKey: Hashable {
  let uti: String
  let mimeType: String
}

struct MediaCount {
  var attachments: Int64 = 0
  var bytes: Int64 = 0
}

struct ChatMediaCount {
  let chat: StatsChatDimension
  var attachments: Int64
  var bytes: Int64
}
