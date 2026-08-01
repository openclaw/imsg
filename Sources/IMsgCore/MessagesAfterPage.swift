public struct MessagesAfterPage: Sendable, Equatable {
  public let messages: [Message]
  public let nextRowID: Int64
  public let hasMore: Bool

  public init(messages: [Message], nextRowID: Int64, hasMore: Bool) {
    self.messages = messages
    self.nextRowID = nextRowID
    self.hasMore = hasMore
  }
}
