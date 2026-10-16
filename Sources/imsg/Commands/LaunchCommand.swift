import Commander
import Foundation
import IMsgCore

enum LaunchCommand {
  static let spec = CommandSpec(
    name: "launch",
    abstract: "Launch Messages.app with dylib injection",
    discussion: """
      Kills any running Messages.app instance, then relaunches it with
      DYLD_INSERT_LIBRARIES set to inject the imsg bridge helper dylib.
      This enables advanced features like typing indicators and read receipts
      that require IMCore framework access.

      If Messages.app is already running with a dylib injected by a different
      imsg version, it is killed and relaunched with the current dylib under
      the launch lock. Pass --force to relaunch even when the running dylib
      matches.

      Requires SIP (System Integrity Protection) to be disabled.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: [
          .make(
            label: "dylib", names: [.long("dylib")],
            help: "Custom path to imsg-bridge-helper.dylib")
        ],
        flags: [
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
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let killOnly = values.flags.contains("killOnly")
    let force = values.flags.contains("force")
    let customDylib = values.option("dylib")

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

    if !runtime.jsonOutput {
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
      if runtime.jsonOutput {
        try JSONLines.print([
          "status": "launched",
          "dylib": resolvedPath,
          "message": "Messages.app launched with dylib injection",
        ])
      } else {
        StdoutWriter.writeLine("Messages.app launched with dylib injection")
      }
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
