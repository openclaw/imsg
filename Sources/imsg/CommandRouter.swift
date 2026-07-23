import Commander
import Foundation

struct CommandRouter {
  /// Exit code returned when a write command is refused because read-only mode
  /// is active. Distinct from the generic failure code (1) so callers can
  /// detect a policy denial deterministically.
  static let readOnlyExitCode: Int32 = 3

  let rootName = "imsg"
  let version: String
  let specs: [CommandSpec]
  let program: Program

  init() {
    self.version = CommandRouter.resolveVersion()
    self.specs = [
      ChatsCommand.spec,
      StatsCommand.spec,
      GroupCommand.spec,
      HistoryCommand.spec,
      WatchCommand.spec,
      SendCommand.spec,
      ReactCommand.spec,
      ReadCommand.spec,
      TypingCommand.spec,
      LaunchCommand.spec,
      StatusCommand.spec,
      RpcCommand.spec,
      CompletionsCommand.spec,
      ScheduledCommand.spec,
      ChatBackgroundCommand.spec,
      // Bridge-backed (require `imsg launch` + SIP off)
      SendRichCommand.spec,
      SendMultipartCommand.spec,
      SendAttachmentCommand.spec,
      StickerCommand.spec,
      PollCommand.spec,
      BridgeReactCommand.spec,
      EditCommand.spec,
      UnsendCommand.spec,
      DeleteMessageCommand.spec,
      NotifyAnywaysCommand.spec,
      ChatCreateCommand.spec,
      ChatNameCommand.spec,
      ChatPhotoCommand.spec,
      ChatAddMemberCommand.spec,
      ChatRemoveMemberCommand.spec,
      ChatLeaveCommand.spec,
      ChatDeleteCommand.spec,
      ChatMarkCommand.spec,
      SearchCommand.spec,
      AccountCommand.spec,
      WhoisCommand.spec,
      NicknameCommand.spec,
      NamePhotoCommand.spec,
    ]
    let descriptor = CommandDescriptor(
      name: rootName,
      abstract: "Send and read iMessage / SMS from the terminal",
      discussion: nil,
      signature: CommandSignature(),
      subcommands: specs.map { $0.descriptor }
    )
    self.program = Program(descriptors: [descriptor])
  }

  func run() async -> Int32 {
    return await run(argv: CommandLine.arguments)
  }

  func run(argv: [String]) async -> Int32 {
    let argv = normalizeArguments(argv)
    if argv.contains("--version") || argv.contains("-V") {
      StdoutWriter.writeLine(version)
      return 0
    }
    if argv.count <= 1 || argv.contains("--help") || argv.contains("-h") {
      printHelp(for: argv)
      return 0
    }

    let (readOnly, resolveArgv) = CommandRouter.extractReadOnly(argv)

    do {
      let invocation = try program.resolve(argv: resolveArgv)
      guard let commandName = invocation.path.last,
        let spec = specs.first(where: { $0.name == commandName })
      else {
        StdoutWriter.writeLine("Unknown command")
        HelpPrinter.printRoot(version: version, rootName: rootName, commands: specs)
        return 1
      }
      let runtime = RuntimeOptions(parsedValues: invocation.parsedValues, readOnly: readOnly)
      if runtime.readOnly && spec.isMutating(for: invocation.parsedValues) {
        emitReadOnlyDenial(command: commandName, json: runtime.jsonOutput)
        return CommandRouter.readOnlyExitCode
      }
      do {
        try await spec.run(invocation.parsedValues, runtime)
        return 0
      } catch is BridgeOutput.EmittedError {
        return 1
      } catch is CommandOutputEmittedError {
        return 1
      } catch {
        StdoutWriter.writeLine(String(describing: error))
        return 1
      }
    } catch let error as CommanderProgramError {
      StdoutWriter.writeLine(error.description)
      if case .missingSubcommand = error {
        HelpPrinter.printRoot(version: version, rootName: rootName, commands: specs)
      }
      return 1
    } catch {
      StdoutWriter.writeLine(String(describing: error))
      return 1
    }
  }

  /// Determines whether read-only mode is requested and returns an argv with any
  /// leading (pre-subcommand) `--read-only` token removed so Commander can
  /// resolve the subcommand normally. Read-only is enabled by the
  /// `IMSG_READ_ONLY` environment variable or by a `--read-only` token anywhere
  /// on the command line. A `--read-only` after the subcommand is left in place
  /// for Commander to parse as a flag (so it is not mistaken for an option
  /// value); `RuntimeOptions` folds that parsed flag back in.
  static func extractReadOnly(_ argv: [String]) -> (readOnly: Bool, argv: [String]) {
    var readOnly = envReadOnly()
    guard argv.count > 1 else { return (readOnly, argv) }
    var result: [String] = [argv[0]]
    var sawCommand = false
    for token in argv.dropFirst() {
      if !sawCommand && token == CommandSignatures.readOnlyFlagName {
        readOnly = true
        continue
      }
      if !token.hasPrefix("-") { sawCommand = true }
      result.append(token)
    }
    return (readOnly, result)
  }

  static func envReadOnly() -> Bool {
    readOnlyEnvValue(ProcessInfo.processInfo.environment["IMSG_READ_ONLY"])
  }

  /// Pure parser for the `IMSG_READ_ONLY` value, kept separate so it can be
  /// tested without mutating the process environment.
  static func readOnlyEnvValue(_ raw: String?) -> Bool {
    guard let raw else { return false }
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true", "yes", "on":
      return true
    default:
      return false
    }
  }

  private func emitReadOnlyDenial(command: String, json: Bool) {
    let message =
      "read-only mode: '\(command)' performs a write or mutation and is disabled"
    guard json else {
      StdoutWriter.writeLine(message)
      return
    }
    let payload: [String: Any] = [
      "ok": false,
      "error": [
        "code": "read_only",
        "message": message,
        "command": command,
      ],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
      let line = String(data: data, encoding: .utf8)
    {
      StdoutWriter.writeLine(line)
    } else {
      StdoutWriter.writeLine(message)
    }
  }

  private func normalizeArguments(_ argv: [String]) -> [String] {
    guard !argv.isEmpty else { return argv }
    var copy = argv
    copy[0] = URL(fileURLWithPath: argv[0]).lastPathComponent
    return copy
  }

  private func printHelp(for argv: [String]) {
    let path = helpPath(from: argv)
    if path.count <= 1 {
      HelpPrinter.printRoot(version: version, rootName: rootName, commands: specs)
      return
    }
    if let spec = specs.first(where: { $0.name == path[1] }) {
      HelpPrinter.printCommand(rootName: rootName, spec: spec)
    } else {
      HelpPrinter.printRoot(version: version, rootName: rootName, commands: specs)
    }
  }

  private func helpPath(from argv: [String]) -> [String] {
    var path: [String] = []
    for token in argv {
      if token == "--help" || token == "-h" { continue }
      if token.hasPrefix("-") { break }
      path.append(token)
    }
    return path
  }

  private static func resolveVersion() -> String {
    if let envVersion = ProcessInfo.processInfo.environment["IMSG_VERSION"],
      !envVersion.isEmpty
    {
      return envVersion
    }
    return IMsgVersion.current
  }
}
