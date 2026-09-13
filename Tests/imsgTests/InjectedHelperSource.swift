import Foundation

func injectedHelperSource() throws -> String {
  let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/IMsgHelper")
  let entry = try String(
    contentsOf: directory.appendingPathComponent("IMsgInjected.m"), encoding: .utf8)
  return try entry.components(separatedBy: "\n").map { line in
    guard line.hasPrefix("#include \""), line.hasSuffix(".inc\"") else { return line }
    let name = String(line.dropFirst("#include \"".count).dropLast())
    return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }.joined(separator: "\n")
}

func stripObjectiveCComments(_ source: String) -> String {
  source
    .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"//.*"#, with: "", options: .regularExpression)
}

func bridgeFunctionBody(named name: String, in source: String) -> String? {
  var searchStart = source.startIndex
  while searchStart < source.endIndex,
    let nameRange = source.range(
      of: name,
      range: searchStart..<source.endIndex)
  {
    searchStart = nameRange.upperBound
    guard let openParenthesis = source[nameRange.upperBound...].firstIndex(of: "(") else {
      return nil
    }
    guard source[nameRange.upperBound..<openParenthesis].allSatisfy(\.isWhitespace) else {
      continue
    }

    var parenthesisDepth = 0
    var index = openParenthesis
    var closeParenthesis: String.Index?
    while index < source.endIndex {
      if source[index] == "(" {
        parenthesisDepth += 1
      } else if source[index] == ")" {
        parenthesisDepth -= 1
        if parenthesisDepth == 0 {
          closeParenthesis = index
          break
        }
      }
      index = source.index(after: index)
    }
    guard let closeParenthesis else { return nil }

    index = source.index(after: closeParenthesis)
    while index < source.endIndex, source[index].isWhitespace {
      index = source.index(after: index)
    }
    guard index < source.endIndex, source[index] == "{" else {
      continue
    }

    let openBrace = index
    var braceDepth = 0
    while index < source.endIndex {
      if source[index] == "{" {
        braceDepth += 1
      } else if source[index] == "}" {
        braceDepth -= 1
        if braceDepth == 0 {
          return String(source[openBrace...index])
        }
      }
      index = source.index(after: index)
    }
  }
  return nil
}
