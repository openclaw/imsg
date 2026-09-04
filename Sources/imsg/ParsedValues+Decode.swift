import Commander

enum ParsedValuesError: Error, CustomStringConvertible {
  case missingOption(String)
  case invalidOption(String)
  case missingArgument(String)

  var description: String {
    switch self {
    case .missingOption(let name):
      return "Missing required option: --\(name)"
    case .invalidOption(let name):
      return "Invalid value for option: --\(name)"
    case .missingArgument(let name):
      return "Missing required argument: \(name)"
    }
  }
}

extension ParsedValues {
  func flag(_ label: String) -> Bool {
    flags.contains(label)
  }

  func option(_ label: String) -> String? {
    options[label]?.last
  }

  func optionValues(_ label: String) -> [String] {
    options[label] ?? []
  }

  func optionInt(_ label: String, name: String? = nil, minimum: Int? = nil) throws -> Int? {
    try integerOption(label, name: name, minimum: minimum)
  }

  func optionInt64(_ label: String, name: String? = nil, minimum: Int64? = nil) throws -> Int64? {
    try integerOption(label, name: name, minimum: minimum)
  }

  func optionChatID() throws -> Int64? {
    try optionInt64("chatID", name: "chat-id", minimum: 1)
  }

  private func integerOption<T: FixedWidthInteger>(
    _ label: String, name: String?, minimum: T?
  ) throws -> T? {
    guard let raw = option(label) else { return nil }
    guard let value = T(raw), minimum.map({ value >= $0 }) ?? true else {
      throw ParsedValuesError.invalidOption(name ?? label)
    }
    return value
  }

  func optionRequired(_ label: String) throws -> String {
    guard let value = option(label), !value.isEmpty else {
      throw ParsedValuesError.missingOption(label)
    }
    return value
  }

  func argument(_ index: Int) -> String? {
    guard positional.indices.contains(index) else { return nil }
    return positional[index]
  }
}
