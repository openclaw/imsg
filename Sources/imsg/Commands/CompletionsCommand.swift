import Commander
import Foundation
import IMsgCore

enum CompletionsCommand {
  static let spec = CommandSpec(
    name: "completions",
    abstract: "Generate shell completions or LLM context",
    discussion: "Outputs completion scripts for bash, zsh, fish, or a Markdown CLI reference.",
    signature: CommandSignature(
      arguments: [
        .make(label: "shell", help: "bash, zsh, fish, or llm", isOptional: true)
      ],
      flags: [CommandSignatures.readOnlyFlag(), CommandSignatures.redactCodesFlag()]
    ),
    usageExamples: [
      "imsg completions bash > ~/.bash_completion.d/imsg",
      "imsg completions zsh > ~/.zsh/completions/_imsg",
      "imsg completions fish > ~/.config/fish/completions/imsg.fish",
      "imsg completions llm",
    ],
    mutation: .read
  ) { values, _ in
    try await run(shell: values.argument(0), specs: CommandRouter().specs)
  }

  static func run(shell: String?, specs: [CommandSpec]) async throws {
    let output = try CompletionGenerator.generate(shell: shell, rootName: "imsg", specs: specs)
    StdoutWriter.writeLine(output)
  }
}

enum CompletionError: Error, CustomStringConvertible, Sendable {
  case missingShell
  case unknownShell(String)

  var description: String {
    switch self {
    case .missingShell:
      return "Missing shell argument. Use: bash, zsh, fish, or llm"
    case .unknownShell(let shell):
      return "Unknown shell '\(shell)'. Use: bash, zsh, fish, or llm"
    }
  }
}

enum CompletionGenerator {
  static func generate(shell: String?, rootName: String, specs: [CommandSpec]) throws -> String {
    guard let shell, !shell.isEmpty else {
      throw CompletionError.missingShell
    }
    switch shell.lowercased() {
    case "bash":
      return BashCompletionGenerator.generate(rootName: rootName, specs: specs)
    case "zsh":
      return ZshCompletionGenerator.generate(rootName: rootName, specs: specs)
    case "fish":
      return FishCompletionGenerator.generate(rootName: rootName, specs: specs)
    case "llm":
      return LLMCompletionGenerator.generate(rootName: rootName, specs: specs)
    default:
      throw CompletionError.unknownShell(shell)
    }
  }

  static let serviceChoices = MessageService.allCases.map(\.rawValue).joined(separator: " ")
  static let reactionChoices = "love like dislike laugh emphasis question"
  static let logLevelChoices = "trace verbose debug info warning error critical"

  static func optionNames(for spec: CommandSpec) -> [String] {
    let signature = spec.signature.flattened()
    return
      (signature.options.flatMap { names($0.names) } + signature.flags.flatMap { names($0.names) })
      .sorted()
  }

  static func zshOptions(for spec: CommandSpec) -> [String] {
    let signature = spec.signature.flattened()
    var result = signature.options.map { option in
      let names = zshNameGroup(option.names)
      let help = escapeZsh(option.help ?? "")
      let longName = primaryLongName(option.names) ?? option.label
      let choices = choicesForOption(longName)
      let value =
        choices.map { ":value:(\($0))" }
        ?? ":value:"
      return "'\(names)[\(help)]\(value)'"
    }
    result += signature.flags.map { flag in
      "'\(zshNameGroup(flag.names))[\(escapeZsh(flag.help ?? ""))]'"
    }
    if spec.name == "completions" {
      result.append("'1:shell:(bash zsh fish llm)'")
    }
    return result
  }

  static func fishOption(
    rootName: String,
    command: String,
    option: OptionDefinition
  ) -> String {
    var line = "complete -c \(rootName) -n '__\(rootName)_using_command \(command)'"
    for name in option.names where !name.isAlias {
      line += fishName(name)
    }
    line += " -d \(shellQuote(option.help ?? ""))"
    if let choices = choicesForOption(primaryLongName(option.names) ?? option.label) {
      line += " -xa \(shellQuote(choices))"
    } else if optionWantsFiles(option) {
      line += " -r -F"
    } else {
      line += " -x"
    }
    return line
  }

  static func fishFlag(rootName: String, command: String, flag: FlagDefinition) -> String {
    var line = "complete -c \(rootName) -n '__\(rootName)_using_command \(command)'"
    for name in flag.names where !name.isAlias {
      line += fishName(name)
    }
    line += " -d \(shellQuote(flag.help ?? ""))"
    return line
  }

  static func usageFragment(for signature: CommandSignature) -> String {
    var parts: [String] = []
    for argument in signature.arguments {
      parts.append(argument.isOptional ? "[\(argument.label)]" : "<\(argument.label)>")
    }
    if !signature.options.isEmpty || !signature.flags.isEmpty {
      parts.append("[options]")
    }
    return parts.joined(separator: " ")
  }

  static func names(_ names: [CommanderName]) -> [String] {
    names.map { name in
      switch name {
      case .short(let value), .aliasShort(let value):
        return "-\(value)"
      case .long(let value), .aliasLong(let value):
        return "--\(value)"
      }
    }
  }

  static func formatNames(_ commandNames: [CommanderName], expectsValue: Bool) -> String {
    names(commandNames).joined(separator: ", ") + (expectsValue ? " <value>" : "")
  }

  static func primaryLongName(_ names: [CommanderName]) -> String? {
    for name in names {
      if case .long(let value) = name {
        return value
      }
    }
    return nil
  }

  static func choicesForOption(_ name: String) -> String? {
    switch name {
    case "service":
      return serviceChoices
    case "reaction":
      return reactionChoices
    case "log-level", "logLevel":
      return logLevelChoices
    default:
      return nil
    }
  }

  static func optionWantsFiles(_ option: OptionDefinition) -> Bool {
    let longName = primaryLongName(option.names) ?? option.label
    return longName == "db" || longName == "file"
      || option.help?.localizedCaseInsensitiveContains("path") == true
  }

  static func zshNameGroup(_ names: [CommanderName]) -> String {
    let visible = names.filter { !$0.isAlias }
    return visible.map { name in
      switch name {
      case .short(let value):
        return "-\(value)"
      case .long(let value):
        return "--\(value)"
      case .aliasShort(let value):
        return "-\(value)"
      case .aliasLong(let value):
        return "--\(value)"
      }
    }.joined(separator: ",")
  }

  static func fishName(_ name: CommanderName) -> String {
    switch name {
    case .short(let value), .aliasShort(let value):
      return " -s \(value)"
    case .long(let value), .aliasLong(let value):
      return " -l \(value)"
    }
  }

  static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "\\'"))'"
  }

  static func escapeZsh(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "'", with: "'\\''")
  }
}

private enum BashCompletionGenerator {
  static func generate(rootName: String, specs: [CommandSpec]) -> String {
    let commands = specs.map(\.name).joined(separator: " ")
    let commandCases = specs.map { spec in
      let options = CompletionGenerator.optionNames(for: spec).joined(separator: " ")
      return """
            \(spec.name))
              COMPREPLY=($(compgen -W "\(options)" -- "$cur"))
              ;;
        """
    }.joined(separator: "\n")

    return """
      # Bash completion for \(rootName)
      # Generated by: \(rootName) completions bash

      _\(rootName)() {
        local cur prev words cword
        if type _init_completion >/dev/null 2>&1; then
          _init_completion || return
        else
          COMPREPLY=()
          words=("${COMP_WORDS[@]}")
          cword=$COMP_CWORD
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"
        fi

        local commands="\(commands)"
        case "$prev" in
          --db|--file)
            COMPREPLY=($(compgen -f -- "$cur"))
            return
            ;;
          --service)
            COMPREPLY=($(compgen -W "\(CompletionGenerator.serviceChoices)" -- "$cur"))
            return
            ;;
          --reaction|-r)
            COMPREPLY=($(compgen -W "\(CompletionGenerator.reactionChoices)" -- "$cur"))
            return
            ;;
          --log-level|--logLevel)
            COMPREPLY=($(compgen -W "\(CompletionGenerator.logLevelChoices)" -- "$cur"))
            return
            ;;
          completions)
            COMPREPLY=($(compgen -W "bash zsh fish llm" -- "$cur"))
            return
            ;;
        esac

        local cmd=""
        local word
        for word in "${words[@]:1:cword-1}"; do
          case "$word" in
            -*) ;;
            *)
              if [[ " $commands " == *" $word "* ]]; then
                cmd="$word"
                break
              fi
              ;;
          esac
        done

        if [[ -z "$cmd" ]]; then
          COMPREPLY=($(compgen -W "$commands --help -h --version -V" -- "$cur"))
          return
        fi

        case "$cmd" in
      \(commandCases)
        esac
      }

      complete -F _\(rootName) \(rootName)
      """
  }
}

private enum ZshCompletionGenerator {
  static func generate(rootName: String, specs: [CommandSpec]) -> String {
    let commandDescriptions =
      specs
      .map { "    '\($0.name):\(CompletionGenerator.escapeZsh($0.abstract))'" }
      .joined(separator: "\n")
    let commandCases = specs.map { spec in
      let optionSpecs = CompletionGenerator.zshOptions(for: spec).map { "      \($0) \\" }
        .joined(separator: "\n")
      return """
            \(spec.name))
              _arguments \\
        \(optionSpecs)
                && return 0
              ;;
        """
    }.joined(separator: "\n")

    return """
      #compdef \(rootName)
      # Zsh completion for \(rootName)
      # Generated by: \(rootName) completions zsh

      _\(rootName)() {
        local context state line
        typeset -A opt_args

        local -a commands
        commands=(
      \(commandDescriptions)
        )

        _arguments -C \\
          '(- *)'{-h,--help}'[Show help]' \\
          '(- *)'{-V,--version}'[Show version]' \\
          '1:command:->command' \\
          '*::arg:->args' \\
          && return 0

        case $state in
          command)
            _describe -t commands '\(rootName) commands' commands
            ;;
          args)
            case $words[2] in
      \(commandCases)
            esac
            ;;
        esac
      }

      _\(rootName) "$@"
      """
  }
}

private enum FishCompletionGenerator {
  static func generate(rootName: String, specs: [CommandSpec]) -> String {
    var lines: [String] = [
      "# Fish completion for \(rootName)",
      "# Generated by: \(rootName) completions fish",
      "",
      "complete -c \(rootName) -f",
      "",
      "function __\(rootName)_needs_command",
      "  set -l cmd (commandline -opc)",
      "  test (count $cmd) -eq 1",
      "end",
      "",
      "function __\(rootName)_using_command",
      "  set -l cmd (commandline -opc)",
      "  test (count $cmd) -gt 1; and contains -- $cmd[2] $argv",
      "end",
      "",
    ]

    for spec in specs {
      let commandName = CompletionGenerator.shellQuote(spec.name)
      let abstract = CompletionGenerator.shellQuote(spec.abstract)
      lines.append(
        "complete -c \(rootName) -n __\(rootName)_needs_command -a \(commandName) -d \(abstract)"
      )
    }
    lines.append("")

    for spec in specs {
      for option in spec.signature.flattened().options {
        lines.append(
          CompletionGenerator.fishOption(rootName: rootName, command: spec.name, option: option))
      }
      for flag in spec.signature.flattened().flags {
        lines.append(
          CompletionGenerator.fishFlag(rootName: rootName, command: spec.name, flag: flag))
      }
      if spec.name == "completions" {
        lines.append(
          "complete -c \(rootName) -n '__\(rootName)_using_command completions' -a 'bash zsh fish llm'"
        )
      }
    }

    return lines.joined(separator: "\n")
  }
}

private enum LLMCompletionGenerator {
  static func generate(rootName: String, specs: [CommandSpec]) -> String {
    var lines: [String] = [
      "# \(rootName) CLI Reference",
      "",
      "macOS Messages.app CLI to send, read, and stream iMessage/SMS.",
      "",
      "## Commands",
      "",
    ]

    for spec in specs {
      lines.append("### \(spec.name)")
      lines.append("")
      lines.append(spec.abstract)
      if let discussion = spec.discussion, !discussion.isEmpty {
        lines.append("")
        lines.append(discussion)
      }
      lines.append("")
      lines.append(
        "Usage: `\(rootName) \(spec.name) \(CompletionGenerator.usageFragment(for: spec.signature))`"
      )
      lines.append("")

      let signature = spec.signature.flattened()
      if !signature.arguments.isEmpty {
        lines.append("Arguments:")
        for argument in signature.arguments {
          let optional = argument.isOptional ? " optional" : ""
          lines.append("- `\(argument.label)`\(optional): \(argument.help ?? "")")
        }
        lines.append("")
      }
      if !signature.options.isEmpty || !signature.flags.isEmpty {
        lines.append("Options:")
        for option in signature.options {
          lines.append(
            "- `\(CompletionGenerator.formatNames(option.names, expectsValue: true))`: \(option.help ?? "")"
          )
        }
        for flag in signature.flags {
          lines.append(
            "- `\(CompletionGenerator.formatNames(flag.names, expectsValue: false))`: \(flag.help ?? "")"
          )
        }
        lines.append("")
      }
      if !spec.usageExamples.isEmpty {
        lines.append("Examples:")
        for example in spec.usageExamples {
          lines.append("- `\(example)`")
        }
        lines.append("")
      }
    }

    return lines.joined(separator: "\n")
  }
}
