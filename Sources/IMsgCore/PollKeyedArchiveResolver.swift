import Foundation

enum PollKeyedArchiveResolver {
  static func resolve(_ plist: Any) -> Any? {
    guard let archive = pollStringDictionary(plist),
      let objects = pollArrayValue(archive["$objects"]),
      let top = pollStringDictionary(archive["$top"])
    else {
      return nil
    }
    let rootUID =
      top["root"].flatMap(uidValue)
      ?? top.values.compactMap(uidValue).first
    guard let rootUID else { return nil }
    var seen = Set<Int>()
    return resolveObject(at: rootUID, objects: objects, seen: &seen, depth: 0)
  }

  private static func resolveObject(
    at index: Int,
    objects: [Any],
    seen: inout Set<Int>,
    depth: Int
  ) -> Any? {
    guard index > 0, index < objects.count, depth < 32 else { return nil }
    if seen.contains(index) { return nil }
    seen.insert(index)
    defer { seen.remove(index) }
    return resolveValue(objects[index], objects: objects, seen: &seen, depth: depth + 1)
  }

  private static func resolveValue(
    _ value: Any,
    objects: [Any],
    seen: inout Set<Int>,
    depth: Int
  ) -> Any? {
    if let uid = uidValue(value) {
      return resolveObject(at: uid, objects: objects, seen: &seen, depth: depth + 1)
    }
    if value is NSNull { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number }
    if let data = value as? Data { return data }
    if let date = value as? Date { return date }

    if let array = pollArrayValue(value) {
      return array.compactMap { child in
        resolveValue(child, objects: objects, seen: &seen, depth: depth + 1)
      }
    }

    guard let dict = pollStringDictionary(value) else { return value }

    if let relative = dict["NS.relative"] {
      let resolvedRelative =
        resolveValue(
          relative,
          objects: objects,
          seen: &seen,
          depth: depth + 1
        ) as? String
      if let base = dict["NS.base"],
        let baseString = resolveValue(base, objects: objects, seen: &seen, depth: depth + 1)
          as? String,
        let relative = resolvedRelative,
        let baseURL = URL(string: baseString)
      {
        return URL(string: relative, relativeTo: baseURL)?.absoluteString ?? relative
      }
      return resolvedRelative
    }

    if let keys = pollArrayValue(dict["NS.keys"]), let values = pollArrayValue(dict["NS.objects"]) {
      var resolved: [String: Any] = [:]
      for (rawKey, rawValue) in zip(keys, values) {
        guard
          let key = resolveValue(rawKey, objects: objects, seen: &seen, depth: depth + 1)
            as? String
        else {
          continue
        }
        if let value = resolveValue(rawValue, objects: objects, seen: &seen, depth: depth + 1) {
          resolved[key] = value
        }
      }
      return resolved
    }

    if let values = pollArrayValue(dict["NS.objects"]) {
      return values.compactMap { child in
        resolveValue(child, objects: objects, seen: &seen, depth: depth + 1)
      }
    }

    var resolved: [String: Any] = [:]
    for (key, rawValue) in dict
    where key != "$class" && key != "$classes" && key != "$classname" {
      if let value = resolveValue(rawValue, objects: objects, seen: &seen, depth: depth + 1) {
        resolved[key] = value
      }
    }
    return resolved
  }

  private static func uidValue(_ value: Any) -> Int? {
    let description = String(describing: value)
    guard let marker = description.range(of: "value = ") else { return nil }
    var digits = ""
    for character in description[marker.upperBound...] {
      guard character.isNumber else { break }
      digits.append(character)
    }
    return Int(digits)
  }
}

func pollArrayValue(_ value: Any?) -> [Any]? {
  guard let value else { return nil }
  if let array = value as? [Any] { return array }
  if let array = value as? NSArray { return array.map { $0 } }
  return nil
}

func pollStringDictionary(_ value: Any?) -> [String: Any]? {
  guard let value else { return nil }
  if let dict = value as? [String: Any] { return dict }
  guard let dict = value as? NSDictionary else { return nil }
  var result: [String: Any] = [:]
  for (key, value) in dict {
    guard let key = key as? String else { continue }
    result[key] = value
  }
  return result
}
