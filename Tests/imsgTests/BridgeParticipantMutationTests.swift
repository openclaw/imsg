import Foundation
import Testing

@Test
func participantMutationsUseCurrentAndLegacySelectors() throws {
  let source = try participantMutationBridgeSource()
  let addBody = try #require(
    participantMutationFunctionBody(named: "handleAddParticipant", in: source))
  let removeBody = try #require(
    participantMutationFunctionBody(named: "handleRemoveParticipant", in: source))

  #expect(addBody.contains(#"vendIMHandle(hr, address, @"iMessage", YES)"#))
  #expect(addBody.contains(#"@"inviteParticipants:reason:""#))
  #expect(addBody.contains(#"@"inviteParticipantsToiMessageChat:reason:""#))
  #expect(removeBody.contains(#"@"removeParticipants:reason:""#))
  #expect(removeBody.contains(#"@"removeParticipantsFromiMessageChat:reason:""#))
}

private func participantMutationBridgeSource() throws -> String {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  return try String(contentsOf: helper, encoding: .utf8)
}

private func participantMutationFunctionBody(named name: String, in source: String) -> String? {
  var searchStart = source.startIndex
  while let nameRange = source.range(of: name, range: searchStart..<source.endIndex) {
    let suffix = source[nameRange.upperBound...]
    guard let openBrace = suffix.firstIndex(of: "{") else { return nil }
    if let semicolon = suffix.firstIndex(of: ";"), semicolon < openBrace {
      searchStart = nameRange.upperBound
      continue
    }
    var depth = 0
    var index = openBrace
    while index < source.endIndex {
      if source[index] == "{" { depth += 1 }
      if source[index] == "}" {
        depth -= 1
        if depth == 0 { return String(source[openBrace...index]) }
      }
      index = source.index(after: index)
    }
    return nil
  }
  return nil
}
