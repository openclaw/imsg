import Commander
import Foundation
import IMsgRPC

struct HelpPrinter {
  static func printRoot(version: String, rootName: String, commands: [CommandSpec]) {
    for line in renderRoot(version: version, rootName: rootName, commands: commands) {
      StdoutWriter.writeLine(line)
    }
  }

  static func printCommand(rootName: String, spec: CommandSpec) {
    for line in renderCommand(rootName: rootName, spec: spec) {
      StdoutWriter.writeLine(line)
    }
  }

  static func renderRoot(version: String, rootName: String, commands: [CommandSpec]) -> [String] {
    var lines: [String] = []
    lines.append("\(rootName) \(version)")
    lines.append("Send and read iMessage / SMS from the terminal")
    lines.append("")
    lines.append("Usage:")
    lines.append("  \(rootName) <command> [options]")
    lines.append("")
    lines.append("Commands:")
    for command in commands {
      lines.append("  \(command.name)\t\(command.abstract)")
    }
    lines.append("")
    lines.append("Run '\(rootName) <command> --help' for details.")
    return lines
  }

  static func renderCommand(rootName: String, spec: CommandSpec) -> [String] {
    var lines: [String] = []
    lines.append("\(rootName) \(spec.name)")
    lines.append(spec.abstract)
    if let discussion = spec.discussion, !discussion.isEmpty {
      lines.append("\n\(discussion)")
    }
    lines.append("")
    lines.append("Usage:")
    lines.append("  \(rootName) \(spec.name) \(usageFragment(for: spec.signature))")
    lines.append("")

    if !spec.signature.arguments.isEmpty {
      lines.append("Arguments:")
      for arg in spec.signature.arguments {
        let optionalMark = arg.isOptional ? "?" : ""
        lines.append("  \(arg.label)\(optionalMark)\t\(arg.help ?? "")")
      }
      lines.append("")
    }

    let options = spec.signature.options
    let flags = spec.signature.flags
    if !options.isEmpty || !flags.isEmpty {
      lines.append("Options:")
      for option in options {
        let names = formatNames(option.names, expectsValue: true)
        lines.append("  \(names)\t\(option.help ?? "")")
      }
      for flag in flags {
        let names = formatNames(flag.names, expectsValue: false)
        lines.append("  \(names)\t\(flag.help ?? "")")
      }
      lines.append("")
    }

    if !spec.usageExamples.isEmpty {
      lines.append("Examples:")
      for example in spec.usageExamples {
        lines.append("  \(example)")
      }
    }
    return lines
  }

  private static func usageFragment(for signature: CommandSignature) -> String {
    var parts: [String] = []
    for argument in signature.arguments {
      let token = argument.isOptional ? "[\(argument.label)]" : "<\(argument.label)>"
      parts.append(token)
    }
    if !signature.options.isEmpty || !signature.flags.isEmpty {
      parts.append("[options]")
    }
    return parts.joined(separator: " ")
  }

  private static func formatNames(_ names: [CommanderName], expectsValue: Bool) -> String {
    let parts = names.map { name -> String in
      switch name {
      case .short(let char):
        return "-\(char)"
      case .long(let value):
        return "--\(value)"
      case .aliasShort(let char):
        return "-\(char)"
      case .aliasLong(let value):
        return "--\(value)"
      }
    }
    let suffix = expectsValue ? " <value>" : ""
    return parts.joined(separator: ", ") + suffix
  }
}
