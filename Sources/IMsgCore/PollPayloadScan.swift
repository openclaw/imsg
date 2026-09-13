import Foundation

struct PollPayloadScan {
  var objects: [Any] = []
  var queryKeys = Set<String>()
  var urlScheme: String?
  var urlHost: String?

  init(payloadData: Data, summaryData: Data) {
    objects.append(contentsOf: PayloadScanner.objects(from: payloadData))
    objects.append(contentsOf: PayloadScanner.objects(from: summaryData))

    var facts = PayloadScannerFacts()
    for object in objects {
      PayloadScanner.collect(from: object, facts: &facts, depth: 0)
    }

    let nestedObjects = facts.data.flatMap { PayloadScanner.objects(from: $0) }
    objects.append(contentsOf: nestedObjects)
    for object in nestedObjects {
      PayloadScanner.collect(from: object, facts: &facts, depth: 0)
    }

    for string in facts.strings {
      if let url = PayloadScanner.url(from: string) {
        facts.urls.append(url)
      }
    }

    for url in facts.urls {
      captureMetadata(from: url)
      if let dataPayload = PayloadScanner.dataURLPayload(from: url) {
        objects.append(contentsOf: PayloadScanner.embeddedObjects(from: dataPayload))
      }
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        continue
      }
      for item in components.queryItems ?? [] {
        queryKeys.insert(item.name)
        guard let value = item.value else { continue }
        objects.append(contentsOf: PayloadScanner.embeddedObjects(from: value))
      }
    }
  }

  private mutating func captureMetadata(from url: URL) {
    if urlScheme == nil {
      urlScheme = url.scheme
    }
    if urlHost == nil {
      urlHost = url.host
    }
  }

  var hasPollURLHint: Bool {
    [urlScheme, urlHost].contains { value in
      value?.localizedCaseInsensitiveContains("poll") == true
    }
  }
}

private struct PayloadScannerFacts {
  var strings: [String] = []
  var urls: [URL] = []
  var data: [Data] = []
  var visitedNodes = 0
}

private enum PayloadScanner {
  static func objects(from data: Data) -> [Any] {
    guard !data.isEmpty else { return [] }
    var objects: [Any] = []

    if let object = try? NSKeyedUnarchiver.unarchivedObject(
      ofClasses: allowedArchiveClasses,
      from: data
    ) {
      objects.append(object)
    }

    if let plist = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) {
      objects.append(plist)
      if let resolved = PollKeyedArchiveResolver.resolve(plist) {
        objects.append(resolved)
      }
    }

    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
      objects.append(json)
    }

    if let string = String(data: data, encoding: .utf8) {
      objects.append(string)
      objects.append(contentsOf: embeddedObjects(from: string))
    }

    return objects
  }

  static func embeddedObjects(from value: String) -> [Any] {
    let decoded = value.removingPercentEncoding ?? value
    var objects: [Any] = []
    if let data = decoded.data(using: .utf8) {
      objects.append(contentsOf: structuredObjects(from: data))
    }
    if let data = base64Data(from: decoded) {
      objects.append(contentsOf: Self.objects(from: data))
    }
    return objects
  }

  static func collect(from value: Any, facts: inout PayloadScannerFacts, depth: Int) {
    guard depth < 32, facts.visitedNodes < 20_000 else { return }
    facts.visitedNodes += 1

    if let url = value as? URL {
      facts.urls.append(url)
      return
    }
    if let url = value as? NSURL {
      facts.urls.append(url as URL)
      return
    }
    if let string = value as? String {
      facts.strings.append(string)
      return
    }
    if let data = value as? Data {
      facts.data.append(data)
      return
    }
    if let dict = pollStringDictionary(value) {
      for child in dict.values {
        collect(from: child, facts: &facts, depth: depth + 1)
      }
      return
    }
    if let array = pollArrayValue(value) {
      for child in array {
        collect(from: child, facts: &facts, depth: depth + 1)
      }
    }
  }

  static func url(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 65_536,
      let components = URLComponents(string: trimmed),
      components.scheme != nil
    else {
      return nil
    }
    return components.url ?? URL(string: trimmed)
  }

  static func dataURLPayload(from url: URL) -> String? {
    guard url.scheme?.lowercased() == "data" else { return nil }
    let absolute = url.absoluteString
    guard let comma = absolute.firstIndex(of: ",") else { return nil }
    let payloadStart = absolute.index(after: comma)
    let end =
      absolute[payloadStart...].firstIndex(where: { $0 == "?" || $0 == "#" })
      ?? absolute.endIndex
    guard payloadStart < end else { return nil }
    let payload = String(absolute[payloadStart..<end])
    return payload.removingPercentEncoding ?? payload
  }

  private static func structuredObjects(from data: Data) -> [Any] {
    var objects: [Any] = []
    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
      objects.append(json)
    }
    if let plist = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) {
      objects.append(plist)
      if let resolved = PollKeyedArchiveResolver.resolve(plist) {
        objects.append(resolved)
      }
    }
    return objects
  }

  private static func base64Data(from value: String) -> Data? {
    let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count >= 8 else { return nil }
    guard
      compact.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "+" || character == "/"
          || character == "-" || character == "_" || character == "="
      })
    else {
      return nil
    }
    var normalized = compact.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: normalized)
  }

  private static let allowedArchiveClasses: [AnyClass] = [
    NSArray.self,
    NSDictionary.self,
    NSString.self,
    NSNumber.self,
    NSData.self,
    NSDate.self,
    NSURL.self,
    NSUUID.self,
    NSNull.self,
  ]
}
