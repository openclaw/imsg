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
            help: "Only kill Messages.app, don't relaunch")
        ]
      )
    ),
    usageExamples: [
      "imsg launch",
      "imsg launch --kill-only",
      "imsg launch --dylib /path/to/dylib",
      "imsg launch --json",
    ],
    mutation: .read
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let killOnly = values.flags.contains("killOnly")
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
      let error =
        "imsg-bridge-helper.dylib not found. Searched:\n"
        + BridgeHelperLocator.searchPaths().map { "  - \($0)" }.joined(separator: "\n")
        + "\n"
        + "Run 'make build-dylib' or specify --dylib <path>"

      if runtime.jsonOutput {
        try JSONLines.print(["status": "error", "error": "dylib_not_found", "message": error])
      } else {
        StdoutWriter.writeLine(error)
      }
      throw IMsgError.typingIndicatorFailed("dylib not found")
    }

    launcher.dylibPath = resolvedPath

    if !runtime.jsonOutput {
      StdoutWriter.writeLine("Using dylib: \(resolvedPath)")
      StdoutWriter.writeLine("Launching Messages.app with injection...")
    }

    do {
      try launcher.ensureRunning()
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
}
