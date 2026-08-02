import IMsgCore

func pluralSuffix(for count: Int) -> String {
  count == 1 ? "" : "s"
}

func displayName(for meta: AttachmentMeta) -> String {
  if !meta.transferName.isEmpty { return meta.transferName }
  if !meta.filename.isEmpty { return meta.filename }
  return "(unknown)"
}

func attachmentMetadataLine(for meta: AttachmentMeta) -> String {
  let name = displayName(for: meta)
  var line =
    "  attachment: name=\(name) mime=\(meta.mimeType) missing=\(meta.missing) path=\(meta.originalPath)"
  if let convertedPath = meta.convertedPath {
    let convertedMime = meta.convertedMimeType ?? ""
    line += " converted_mime=\(convertedMime) converted_path=\(convertedPath)"
  }
  return line
}

func pollDisplayText(for poll: MessagePollEvent) -> String {
  switch poll.kind {
  case .created:
    let question = poll.question ?? "poll"
    let options = poll.options?.map(\.text).joined(separator: " / ") ?? ""
    return options.isEmpty ? "[poll created] \(question)" : "[poll created] \(question): \(options)"
  case .vote:
    if let votes = poll.votes {
      var participantOrder: [String] = []
      var selectionsByParticipant: [String: [String]] = [:]
      for vote in votes where vote.eventType != "removed" {
        let participant = vote.participant ?? "someone"
        let option = vote.optionText ?? vote.optionID
        if selectionsByParticipant[participant] == nil {
          participantOrder.append(participant)
          selectionsByParticipant[participant] = []
        }
        if selectionsByParticipant[participant]?.contains(option) == false {
          selectionsByParticipant[participant]?.append(option)
        }
      }
      let snapshots = participantOrder.compactMap { participant -> String? in
        guard let selections = selectionsByParticipant[participant], !selections.isEmpty else {
          return nil
        }
        return "\(participant) selected \(selections.joined(separator: " / "))"
      }
      if !snapshots.isEmpty {
        return "[poll vote] \(snapshots.joined(separator: "; "))"
      }
      return "[poll vote] no options selected"
    }
    guard let vote = poll.vote else {
      return "[poll vote] no options selected"
    }
    let participant = vote.participant ?? "someone"
    let option = vote.optionText ?? vote.optionID
    let action = vote.eventType ?? "selected"
    return "[poll vote] \(participant) \(action) \(option)"
  case .unknown:
    return "[poll unknown]"
  }
}
