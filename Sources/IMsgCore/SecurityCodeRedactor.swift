import Foundation

/// Best-effort redaction of texted security/verification codes (2FA, OTP,
/// bank and vendor verification codes) from message text, for callers that
/// don't want a downstream consumer — an AI agent in particular — to see live
/// codes.
///
/// This is a heuristic, not a guarantee. Real-world SMS OTP messages were
/// mined from a live chat.db to derive it: the code can appear either before
/// or after the keyword ("123456 is your code" is at least as common as
/// "code: 123456" — it's the autofill-friendly format several major senders
/// use), and some senders format it with internal dashes ("657-265"). It is
/// deliberately restricted to digits and dashes, so alphanumeric codes (e.g.
/// "7fpa1i") are not redacted — accepted as a known, rare miss.
public enum SecurityCodeRedactor {
  public static let placeholder = "[redacted]"

  private static let keyword = "(?:code|pin|otp|passcode|authentication)"
  private static let token = "\\d[\\d\\-]{2,8}\\d"
  private static let windowChars = 60

  // The gap between keyword and token deliberately excludes digits. Without
  // that restriction, a real but unmatchable code right next to the keyword
  // (e.g. the alphanumeric "7fpa1i" in "verification code is: 7fpa1i") gets
  // skipped over by the lazy quantifier, which then keeps searching and can
  // latch onto an unrelated digit run later in the message (e.g. a support
  // phone number). Excluding digits from the gap means the match fails
  // outright at that keyword occurrence instead of reaching past it.
  private static let forward = try! NSRegularExpression(
    pattern: "\\b\(keyword)\\b([^\\d]{0,\(windowChars)})\\b(\(token))\\b",
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private static let backward = try! NSRegularExpression(
    pattern: "\\b(\(token))\\b([^\\d]{0,\(windowChars)})\\b\(keyword)\\b",
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private static let url = try! NSRegularExpression(
    pattern: "https?://\\S+|www\\.\\S+",
    options: [.caseInsensitive]
  )

  /// Returns `text` with the nearest code-shaped token next to a security-code
  /// keyword replaced by `placeholder`, or `text` unchanged if nothing matched.
  public static func redact(_ text: String) -> String {
    guard let range = bestMatchRange(in: text) else { return text }
    return (text as NSString).replacingCharacters(in: range, with: placeholder)
  }

  public static func redact(_ text: String?) -> String? {
    guard let text else { return nil }
    return redact(text)
  }

  private static func bestMatchRange(in text: String) -> NSRange? {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard full.length > 0 else { return nil }
    let urlRanges = url.matches(in: text, options: [], range: full).map { $0.range }

    // Leftmost, URL-excluded match for a given direction. Stopping at the
    // first valid match (rather than scanning every keyword occurrence in the
    // message) matters: several real senders repeat "code" multiple times in
    // one message (once naming the real code, again in a decoy like "didn't
    // request a code? call 1-800-..."), and taking the first pairing reliably
    // lands on the real code instead of a support phone number mentioned
    // later near a second, unrelated "code".
    func nearestValidMatch(_ regex: NSRegularExpression, tokenGroup: Int, gapGroup: Int) -> (
      gap: Int, range: NSRange
    )? {
      var offset = 0
      while offset < full.length {
        let searchRange = NSRange(location: offset, length: full.length - offset)
        guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else {
          return nil
        }
        let tokenRange = match.range(at: tokenGroup)
        let overlapsURL = urlRanges.contains {
          NSIntersectionRange($0, tokenRange).length > 0
        }
        if overlapsURL {
          offset = match.range.location + max(match.range.length, 1)
          continue
        }
        return (match.range(at: gapGroup).length, tokenRange)
      }
      return nil
    }

    let fwd = nearestValidMatch(forward, tokenGroup: 2, gapGroup: 1)
    let bwd = nearestValidMatch(backward, tokenGroup: 1, gapGroup: 2)

    switch (fwd, bwd) {
    case (let f?, let b?):
      return f.gap <= b.gap ? f.range : b.range
    case (let f?, nil):
      return f.range
    case (nil, let b?):
      return b.range
    case (nil, nil):
      return nil
    }
  }
}
