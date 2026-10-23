import Commander
import Foundation
import IMsgCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum LaunchCommand {
  static let spec = CommandSpec(
    name: "launch",
    abstract: "Launch Messages.app with dylib injection",
    discussion: """
      Ensures Messages.app is running with DYLD_INSERT_LIBRARIES set to
      inject the imsg bridge helper dylib. Reuses a healthy current helper.
      This enables advanced features like typing indicators and read receipts
      that require IMCore framework access.

      If Messages.app is already running with a dylib injected by a different
      imsg version, it is killed and relaunched with the current dylib under
      the launch lock. Pass --force to relaunch even when the running dylib
      matches.

      --install-agent installs and loads an opt-in login LaunchAgent that runs
      this check at login and every 300 seconds (minimum 60 via --agent-interval).
      --uninstall-agent unloads and removes it. Neither flag can be combined
      with --force or --kill-only. Headless Macs need automatic login.
      Non-interactive successful launches are quiet; JSON output is unchanged.

      Requires SIP (System Integrity Protection) to be disabled.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: [
          .make(
            label: "dylib", names: [.long("dylib")],
            help: "Custom path to imsg-bridge-helper.dylib"),
          .make(
            label: "agentInterval", names: [.long("agent-interval")],
            help: "Agent interval in seconds (default 300, minimum 60; requires --install-agent)"),
        ],
        flags: [
          .make(
            label: "installAgent", names: [.long("install-agent")],
            help: "Install and load the opt-in bridge login agent"),
          .make(
            label: "uninstallAgent", names: [.long("uninstall-agent")],
            help: "Unload and remove the bridge login agent"),
          .make(
            label: "killOnly", names: [.long("kill-only")],
            help: "Only kill Messages.app, don't relaunch"),
          .make(
            label: "force", names: [.long("force")],
            help: "Relaunch even when Messages already runs the current dylib"),
        ]
      )
    ),
    usageExamples: [
      "imsg launch",
      "imsg launch --force",
      "imsg launch --kill-only",
      "imsg launch --dylib /path/to/dylib",
      "imsg launch --json",
      "imsg launch --install-agent",
      "imsg launch --install-agent --agent-interval 600 --json",
      "imsg launch --uninstall-agent",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let interval = try validateAgentOptions(values)
    let killOnly = values.flags.contains("killOnly")
    let force = values.flags.contains("force")
    let customDylib = values.option("dylib")
    let installAgent = values.flags.contains("installAgent")
    let uninstallAgent = values.flags.contains("uninstallAgent")
    let interactive = isatty(STDOUT_FILENO) != 0

    if uninstallAgent {
      let agent = try makeAgent(interval: interval, dylib: nil)
      try agent.uninstall(userID: getuid())
      try reportAgent(agent, status: "unloaded", runtime: runtime)
      return
    }

    if !interactive && !installAgent && !killOnly {
      BridgeLaunchAgent.trimLog(at: BridgeLaunchAgent.logPath(homeDirectory: NSHomeDirectory()))
    }

    let launcher = MessagesLauncher.shared

    if killOnly {
      if !runtime.jsonOutput {
        StdoutWriter.writeLine("Killing Messages.app...")
      }
      launcher.killMessages()
      try await Task.sleep(nanoseconds: 1_000_000_000)
      if runtime.jsonOutput {
        try JSONLines.print(["status": "killed", "message": "Messages.app terminated"])
      } else {
        StdoutWriter.writeLine("Messages.app terminated")
      }
      return
    }

    switch MessagesLauncher.currentSIPStatus() {
    case .enabled:
      let message =
        "SIP is enabled. Refusing to inject into Messages.app. "
        + "Disable SIP in Recovery mode (`csrutil disable`) before running `imsg launch`."
      if runtime.jsonOutput {
        try JSONLines.print(["status": "error", "error": "sip_enabled", "message": message])
      } else {
        StdoutWriter.writeLine(message)
      }
      throw IMsgError.typingIndicatorFailed(message)
    case .unknown(let details):
      let message =
        "Unable to determine SIP status. Refusing to inject into Messages.app. Details: \(details)"
      if runtime.jsonOutput {
        try JSONLines.print(["status": "error", "error": "sip_unknown", "message": message])
      } else {
        StdoutWriter.writeLine(message)
      }
      throw IMsgError.typingIndicatorFailed(message)
    case .disabled:
      break
    }

    let dylibPath = resolveDylibPath(custom: customDylib)

    guard let resolvedPath = dylibPath else {
      let error = dylibNotFoundMessage(custom: customDylib)

      if runtime.jsonOutput {
        try JSONLines.print(["status": "error", "error": "dylib_not_found", "message": error])
      } else {
        StdoutWriter.writeLine(error)
      }
      throw IMsgError.typingIndicatorFailed("dylib not found")
    }

    if installAgent {
      let agent = try makeAgent(
        interval: interval, dylib: customDylib, automaticDylib: resolvedPath)
      try agent.install(userID: getuid())
      try reportAgent(agent, status: "loaded", runtime: runtime)
      return
    }

    launcher.dylibPath = resolvedPath

    // A dylib injected by an older release keeps answering the readiness ping,
    // so ensureRunning() would silently keep the stale bridge. Pass the CLI's
    // version as the expectation: the launcher's readiness check (which runs
    // under the launch coordinator's lock) reuses the running helper only when
    // it reports the current version and kills + relaunches otherwise. Forcing
    // skips the check entirely. No preliminary probe happens here — probing
    // before the lock would race a competing CLI for the legacy IPC response
    // files, so all version inspection is done inside the coordinated
    // readiness check.
    let expectedHelperVersion = force ? nil : IMsgVersion.current

    if !runtime.jsonOutput && interactive {
      StdoutWriter.writeLine("Using dylib: \(resolvedPath)")
      StdoutWriter.writeLine("Launching Messages.app with injection...")
    }

    do {
      // Both paths replace through the coordinator: the readiness check (and
      // the skip when forcing) runs under the launch lock, so overlapping
      // launchers serialize and recheck instead of double-killing Messages.
      try await launcher.ensureRunning(
        expectedHelperVersion: expectedHelperVersion,
        force: force
      )
      try reportLaunchSuccess(dylib: resolvedPath, runtime: runtime, interactive: interactive)
    } catch {
      if runtime.jsonOutput {
        try JSONLines.print([
          "status": "error",
          "dylib": resolvedPath,
          "error": "\(error)",
        ])
      } else {
        StdoutWriter.writeLine("Failed to launch: \(error)")
      }
      throw error
    }
  }

}

extension LaunchCommand {
  static func validateAgentOptions(_ values: ParsedValues) throws -> Int {
    let agentFlags = values.flags.intersection(["installAgent", "uninstallAgent"])
    if !agentFlags.isEmpty,
      agentFlags.count > 1 || !values.flags.intersection(["killOnly", "force"]).isEmpty
    {
      throw BridgeLaunchAgent.Failure(
        "--install-agent and --uninstall-agent are mutually exclusive with each other, --kill-only, and --force."
      )
    }
    guard let rawInterval = values.option("agentInterval") else {
      return BridgeLaunchAgent.defaultInterval
    }
    guard values.flags.contains("installAgent") else {
      throw BridgeLaunchAgent.Failure("--agent-interval requires --install-agent.")
    }
    guard let interval = Int(rawInterval), interval >= BridgeLaunchAgent.minimumInterval else {
      throw BridgeLaunchAgent.Failure("--agent-interval must be an integer of at least 60 seconds.")
    }
    return interval
  }

  static func reportLaunchSuccess(dylib: String, runtime: RuntimeOptions, interactive: Bool) throws
  {
    if runtime.jsonOutput {
      try JSONLines.print([
        "status": "launched", "dylib": dylib,
        "message": "Messages.app launched with dylib injection",
      ])
    } else if interactive {
      StdoutWriter.writeLine("Messages.app launched with dylib injection")
    }
  }

  private static func makeAgent(
    interval: Int, dylib: String?, automaticDylib: String? = nil
  ) throws -> BridgeLaunchAgent {
    let directory = FileManager.default.currentDirectoryPath
    let executable = try BridgeLaunchAgent.executablePath(
      invoked: CommandLine.arguments[0], currentDirectory: directory,
      searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "",
      isExecutable: FileManager.default.isExecutableFile(atPath:))
    return try BridgeLaunchAgent(
      executable: executable, currentDirectory: directory,
      homeDirectory: NSHomeDirectory(), interval: interval, dylib: dylib,
      automaticDylib: automaticDylib)
  }

  static func reportAgent(
    _ agent: BridgeLaunchAgent, status: String, runtime: RuntimeOptions
  ) throws {
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "status": status, "label": BridgeLaunchAgent.label,
        "plist": agent.plistPath, "program": agent.program, "interval": agent.interval,
      ])
    } else {
      StdoutWriter.writeLine("Bridge agent \(status): \(agent.plistPath)")
    }
  }

  private static func resolveDylibPath(custom: String?) -> String? {
    BridgeHelperLocator.resolve(customPath: custom)
  }

  static func dylibNotFoundMessage(custom: String?) -> String {
    if let custom {
      return "imsg-bridge-helper.dylib not found at --dylib path: \(custom)\n"
        + "Check the supplied path or omit --dylib to use automatic discovery."
    }
    return "imsg-bridge-helper.dylib not found. Searched:\n"
      + BridgeHelperLocator.searchPaths().map { "  - \($0)" }.joined(separator: "\n")
      + "\n"
      + "Run 'make build-dylib' or specify --dylib <path>"
  }
}
