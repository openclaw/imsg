import Foundation
import SQLite

extension MessageStore {
  func message(
    from decoded: DecodedMessageRow,
    _ db: Connection,
    parentCache: inout ReplyParentCache,
    pollOptionCache: inout PollOptionTextCache
  ) throws -> Message {
    let poll = try enrichedPollEvent(
      decoded.poll,
      db: db,
      cache: &pollOptionCache
    )
    let reaction = decodeReaction(
      associatedType: decoded.associatedType,
      associatedGUID: decoded.associatedGUID,
      text: decoded.text
    )
    let replyToGUID = routedReplyToGUID(decoded)
    let threadOriginatorGUID =
      reaction.isReaction || decoded.threadOriginatorGUID.isEmpty
      ? nil : decoded.threadOriginatorGUID
    let threadOriginatorPart =
      reaction.isReaction || decoded.threadOriginatorPart.isEmpty
      ? nil : decoded.threadOriginatorPart
    let parent =
      reaction.isReaction
      ? nil
      : enrichedReplyContext(
        db,
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        cache: &parentCache
      )

    return Message(
      rowID: decoded.rowID,
      chatID: decoded.chatID,
      sender: decoded.sender,
      text: decoded.text,
      date: decoded.date,
      isFromMe: decoded.isFromMe,
      service: decoded.service,
      handleID: decoded.handleID,
      attachmentsCount: decoded.attachments,
      guid: decoded.guid,
      routing: Message.RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        threadOriginatorPart: threadOriginatorPart,
        destinationCallerID: decoded.destinationCallerID.isEmpty
          ? nil : decoded.destinationCallerID,
        replyToText: parent?.text,
        replyToSender: parent?.sender
      ),
      balloonBundleID: decoded.balloonBundleID.isEmpty ? nil : decoded.balloonBundleID,
      reaction: Message.ReactionMetadata(
        isReaction: reaction.isReaction,
        reactionType: reaction.reactionType,
        isReactionAdd: reaction.isReactionAdd,
        reactedToGUID: reaction.reactedToGUID
      ),
      poll: poll,
      isRead: decoded.isRead,
      dateRead: decoded.dateRead
    )
  }

  func precedingTextMessageForURLPreview(_ preview: Message, db: Connection) throws -> Message? {
    guard isURLPreviewBalloon(preview) else { return nil }
    let selection = MessageRowSelection(store: self, includeChatID: true)
    let reactionFilter =
      schema.hasReactionColumns
      ? "AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    let sql = """
      SELECT \(selection.selectList)
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID < ?
        AND cmj.chat_id = ?
        \(reactionFilter)
      ORDER BY m.ROWID DESC
      """
    let rows = try db.prepareRowIterator(sql, bindings: [preview.rowID, preview.chatID])
    var previews = [preview]
    var parentCache: ReplyParentCache = [:]
    var pollOptionCache = PollOptionTextCache()
    while let row = try rows.failableNext() {
      let decoded = try decodeMessageRow(
        row,
        columns: selection.columns,
        fallbackChatID: preview.chatID
      )
      let previous = try message(
        from: decoded,
        db,
        parentCache: &parentCache,
        pollOptionCache: &pollOptionCache
      )
      if isURLPreviewBalloon(previous) {
        previews.append(previous)
        continue
      }
      // One text send can produce a contiguous row per URL. Validate the entire
      // run so an unrelated message still remains a hard coalescing boundary.
      return previews.allSatisfy {
        canCoalesceURLPreview(textMessage: previous, previewMessage: $0)
      } ? previous : nil
    }
    return nil
  }
}
