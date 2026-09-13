import Foundation
import IMsgCore

extension RPCServer {
  func handlePollSend(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      RPCParameterKeys.replyTarget,
      [
        "question", "options", "option", "creator_handle", "creatorHandle", "comment",
        "suppress_comment", "suppressComment",
      ]
    )
    let params = try RPCParameters(params, method: "poll.send", supportedKeys: supportedKeys)
    guard let question = try params.string("question"), !question.isEmpty else {
      throw RPCError.invalidParams("question is required")
    }
    let options = try rpcPollOptionsParam(params)
    let creatorHandle = try params.string("creator_handle", aliases: ["creatorHandle"])
    let reply = try params.string(
      "reply_to", aliases: ["replyTo", "reply_to_guid", "message_guid"])
    let commentValue = try params.string("comment")
    let suppressComment =
      try params.boolean("suppress_comment", aliases: ["suppressComment"]) ?? false
    if commentValue != nil, suppressComment {
      throw RPCError.invalidParams("comment cannot be combined with suppress_comment: true")
    }
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      "question": question,
      "options": options,
    ]
    if let creatorHandle, !creatorHandle.isEmpty {
      bridgeParams["creatorHandle"] = creatorHandle
    }
    if let reply, !reply.isEmpty {
      bridgeParams["selectedMessageGuid"] = reply
    }

    let data = try await invokeBridge(action: .sendPoll, params: bridgeParams)
    var result: [String: Any] = [
      "ok": true,
      "event": "imessage.poll.created",
    ]
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
    if let poll = data["poll"] as? [String: Any] {
      result["poll"] = poll
    }

    // Messages never renders the poll title on the balloon, so send the question
    // (or an explicit `comment` override) as a PLAIN caption message right after
    // the poll — matching how the native "comment or Send" field renders. Not a
    // threaded reply: native poll comments carry no thread metadata, so a reply
    // would decorate the balloon with a connector line. Outbound (from_me) rows
    // are cached and never re-processed, so no poll<->comment link is needed.
    // Callers pass only `question`; the caption appears for free and the agent
    // needs no knowledge of this. Best-effort: the poll already succeeded, so a
    // comment failure must not fail the RPC.
    let comment = commentValue.flatMap { $0.isEmpty ? nil : $0 } ?? question
    var poisonAfterResponse: DeliveryFailure?
    let pollGuid = (data["messageGuid"] as? String) ?? ""
    let pollDescription = pollGuid.isEmpty ? "queued poll" : "poll \(pollGuid)"
    if suppressComment || comment.isEmpty {
      result["comment"] = PollCaptionStatus.suppressed
    } else {
      do {
        let captionData = try await invokeBridge(
          action: .sendMessage,
          params: [
            "chatGuid": chatGUID,
            "message": comment,
          ])
        // The bridge acknowledging the send is not proof the caption row
        // reached the chat, and an accepted-but-absent caption leaves exactly
        // the question-less balloon this status exists to expose.
        let captionGUID = (captionData["messageGuid"] as? String) ?? ""
        let outcome = await captionVerifier(
          captionGUID, chatGUID, await databaseResources.available()?.store)
        result["comment"] = PollCaptionStatus.status(
          forVerification: outcome, messageGUID: captionGUID)
        if outcome == .unknown {
          FileHandle.standardError.write(
            Data(
              "[imsg] poll.send: caption \(captionGUID) delivery was not verified in \(chatGUID); automatic retry is unsafe\n"
                .utf8))
        }
      } catch let failure as DeliveryFailure {
        if failure.disposition == .stillInFlight {
          poisonAfterResponse = failure
        }
        result["comment"] = PollCaptionStatus.failed(failure)
        let failureState = failure.retrySafe ? "failed before dispatch" : "delivery unresolved"
        FileHandle.standardError.write(
          Data(
            "[imsg] poll.send: comment echo \(failureState) for \(pollDescription): \(failure)\n"
              .utf8))
      } catch {
        result["comment"] = PollCaptionStatus.failed(error)
        FileHandle.standardError.write(
          Data("[imsg] poll.send: comment echo failed for \(pollDescription): \(error)\n".utf8))
      }
    }
    // `ok` stays true when only the caption failed: the poll balloon really did
    // land, and a caller that treats this as a failed send would re-send and
    // duplicate it. `comment` reports confirmed failure separately from an
    // outcome that is still unknown.
    respond(id: id, result: result)
    if let poisonAfterResponse {
      throw RPCMutationPoisonSignal(failure: poisonAfterResponse)
    }
  }

  func handlePollVote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(
      params: params, id: id, remove: false, method: "poll.vote")
  }

  func handlePollUnvote(params: [String: Any], id: Any?) async throws {
    try await handlePollVoteMutation(
      params: params, id: id, remove: true, method: "poll.unvote")
  }

  private func handlePollVoteMutation(
    params rawParams: [String: Any],
    id: Any?,
    remove: Bool,
    method: String
  ) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      [
        "poll_guid", "pollGuid", "poll_message_guid", "message_guid", "message_id",
        "option_id", "optionId", "optionIdentifier", "option_index", "optionIndex", "option",
      ]
    )
    let params = try RPCParameters(rawParams, method: method, supportedKeys: supportedKeys)
    guard
      let pollGUID = try params.string(
        "poll_guid",
        aliases: ["pollGuid", "poll_message_guid", "message_guid", "message_id"]),
      !pollGUID.isEmpty
    else {
      throw RPCError.invalidParams("poll_guid is required")
    }
    let directOptionID = try params.string(
      "option_id", aliases: ["optionId", "optionIdentifier"]
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    let optionIndex = try params.integer("option_index", aliases: ["optionIndex"])
    let optionText = try params.string("option")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let selectors = [
      directOptionID?.isEmpty == false,
      optionIndex != nil,
      optionText?.isEmpty == false,
    ]
    guard selectors.contains(true) else {
      throw RPCError.invalidParams("one of option_id, option_index, or option is required")
    }
    guard selectors.filter({ $0 }).count == 1 else {
      throw RPCError.invalidParams("choose exactly one of option_id, option_index, or option")
    }
    // Resolve every selector against decoded options, so callers cannot vote
    // against an arbitrary non-poll GUID or supply caller-trusted option text.
    let database = try await databaseResources.require()
    let chatGUID = try await resolveChatGUIDParam(params)
    let pollOptions = try database.store.pollOptions(guid: pollGUID)
    guard !pollOptions.isEmpty else {
      throw RPCError.invalidParams("poll \(pollGUID) not found or not decodable")
    }

    let matchedOption: MessagePollOption
    if let directOptionID, !directOptionID.isEmpty {
      guard let option = pollOptions.first(where: { $0.id == directOptionID }) else {
        throw RPCError.invalidParams(
          "option_id \(directOptionID) is not an option of poll \(pollGUID)")
      }
      matchedOption = option
    } else if let optionIndex {
      guard optionIndex >= 1, optionIndex <= pollOptions.count else {
        throw RPCError.invalidParams(
          "option_index \(optionIndex) out of range (1...\(pollOptions.count))")
      }
      matchedOption = pollOptions[optionIndex - 1]
    } else {
      let text = optionText ?? ""
      guard
        let option = pollOptions.first(where: {
          $0.text.caseInsensitiveCompare(text) == .orderedSame
        })
      else {
        let available = pollOptions.map(\.text).joined(separator: ", ")
        throw RPCError.invalidParams("option \"\(text)\" (available: \(available))")
      }
      matchedOption = option
    }
    let optionID = matchedOption.id
    var bridgeParams: [String: Any] = [
      "chatGuid": chatGUID,
      // Native votes associate to the bare poll GUID (strip a leading p:<part>/).
      "pollMessageGuid": barePollGuid(pollGUID),
      "optionIdentifier": optionID,
    ]
    if !matchedOption.text.isEmpty {
      bridgeParams["optionText"] = matchedOption.text
    }
    if remove {
      let selectedOptionIDs = try database.store.pollSelectedOptionIDs(guid: pollGUID)
      guard selectedOptionIDs.contains(optionID) else {
        throw RPCError.invalidParams("option_id \(optionID) is not currently selected")
      }
      bridgeParams["remainingOptionIdentifiers"] = selectedOptionIDs.filter { $0 != optionID }
    }

    let data = try await invokeBridge(
      action: remove ? .sendPollUnvote : .sendPollVote,
      params: bridgeParams)
    var result: [String: Any] = [
      "ok": true,
      "event": remove ? "imessage.poll.unvoted" : "imessage.poll.voted",
      // Callers use the resolved option to suppress a redundant text reply that
      // just restates the vote, so return it alongside the poll linkage.
      "poll_guid": barePollGuid(pollGUID),
      "option_id": matchedOption.id,
      "option_text": matchedOption.text,
    ]
    if let remaining = bridgeParams["remainingOptionIdentifiers"] as? [String] {
      result["remaining_option_ids"] = remaining
    }
    if let guid = data["messageGuid"] as? String, !guid.isEmpty {
      result["guid"] = guid
      result["message_id"] = guid
    }
    respond(id: id, result: result)
  }

}
