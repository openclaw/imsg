import Foundation

enum DurationParser {
  static func parse(_ value: String) -> TimeInterval? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let seconds = Double(trimmed) { return validated(seconds) }

    let units: [(suffix: String, multiplier: Double)] = [
      ("ms", 0.001),
      ("s", 1),
      ("m", 60),
      ("h", 3600),
    ]
    let scanner = Scanner(string: trimmed)
    scanner.locale = Locale(identifier: "en_US_POSIX")
    scanner.charactersToBeSkipped = nil
    var seconds: TimeInterval = 0
    while !scanner.isAtEnd {
      guard let amount = scanner.scanDouble(), amount >= 0,
        let unit = units.first(where: { scanner.scanString($0.suffix) != nil })
      else { return nil }
      seconds += amount * unit.multiplier
    }
    return validated(seconds)
  }

  private static func validated(_ seconds: TimeInterval) -> TimeInterval? {
    guard seconds >= 0,
      UInt64(exactly: (seconds * 1_000_000_000).rounded(.towardZero)) != nil
    else { return nil }
    return seconds
  }
}
