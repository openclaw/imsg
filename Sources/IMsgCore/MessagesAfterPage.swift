public struct MessagesAfterPage: Sendable, Equatable {
  public let messages: [Message]
  /// Physical scan cursor scoped to the same Messages database instance.
  /// Discard it after that database is replaced, restored, or recreated.
  public let nextRowID: Int64
  public let hasMore: Bool

  public init(messages: [Message], nextRowID: Int64, hasMore: Bool) {
    self.messages = messages
    self.nextRowID = nextRowID
    self.hasMore = hasMore
  }
}
