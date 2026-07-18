import Foundation

extension Message {
  var physicalCompletionRowID: Int64 {
    max(rowID, urlPreview?.rowID ?? rowID)
  }

  public struct URLPreviewMetadata: Sendable, Equatable {
    public let rowID: Int64
    public let guid: String
    public let balloonBundleID: String
    public let date: Date

    public init(rowID: Int64, guid: String, balloonBundleID: String, date: Date) {
      self.rowID = rowID
      self.guid = guid
      self.balloonBundleID = balloonBundleID
      self.date = date
    }
  }

  public func withURLPreview(_ preview: URLPreviewMetadata, text replacementText: String? = nil)
    -> Message
  {
    Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: replacementText ?? text,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      routing: RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        threadOriginatorPart: threadOriginatorPart,
        destinationCallerID: destinationCallerID,
        replyToText: replyToText,
        replyToSender: replyToSender
      ),
      balloonBundleID: balloonBundleID,
      urlPreview: preview,
      cursorRowID: cursorRowID,
      reaction: ReactionMetadata(
        isReaction: isReaction,
        reactionType: reactionType,
        isReactionAdd: isReactionAdd,
        reactedToGUID: reactedToGUID
      ),
      poll: poll,
      isRead: isRead,
      dateRead: dateRead
    )
  }

  func withCursorRowID(_ cursorRowID: Int64) -> Message {
    Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: text,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      routing: RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        threadOriginatorPart: threadOriginatorPart,
        destinationCallerID: destinationCallerID,
        replyToText: replyToText,
        replyToSender: replyToSender
      ),
      balloonBundleID: balloonBundleID,
      urlPreview: urlPreview,
      cursorRowID: cursorRowID,
      reaction: ReactionMetadata(
        isReaction: isReaction,
        reactionType: reactionType,
        isReactionAdd: isReactionAdd,
        reactedToGUID: reactedToGUID
      ),
      poll: poll,
      isRead: isRead,
      dateRead: dateRead
    )
  }
}
