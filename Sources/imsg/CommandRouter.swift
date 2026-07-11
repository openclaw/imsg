import Commander
import Foundation

struct CommandRouter {
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

    do {
      let invocation = try program.resolve(argv: argv)
      guard let commandName = invocation.path.last,
        let spec = specs.first(where: { $0.name == commandName })
      else {
        StdoutWriter.writeLine("Unknown command")
        HelpPrinter.printRoot(version: version, rootName: rootName, commands: specs)
        return 1
      }
      let runtime = RuntimeOptions(parsedValues: invocation.parsedValues)
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
