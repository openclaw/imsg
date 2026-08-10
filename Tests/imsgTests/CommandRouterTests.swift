import Foundation
import Testing

@testable import imsg

@Test
func commandRouterPrintsVersionFromEnv() async {
  setenv("IMSG_VERSION", "9.9.9-test", 1)
  defer { unsetenv("IMSG_VERSION") }
  let router = CommandRouter()
  #expect(router.version == "9.9.9-test")
  let (_, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "--version"])
  }
  #expect(status == 0)
}

@Test
func commandRouterPrintsHelp() async {
  let router = CommandRouter()
  let (_, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "--help"])
  }
  #expect(status == 0)
}

@Test
func commandRouterUnknownCommand() async {
  let router = CommandRouter()
  let (_, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "nope"])
  }
  #expect(status == 1)
}

@Test
func executableWrapperPropagatesRouterStatus() throws {
  let version = try runIMsgProcess(["--version"], environment: ["IMSG_VERSION": "9.9.9-process"])
  #expect(version.status == 0)
  #expect(version.output.trimmingCharacters(in: .whitespacesAndNewlines) == "9.9.9-process")

  let invalid = try runIMsgProcess(["nope"])
  #expect(invalid.status == 1)
  #expect(invalid.output.contains("nope") || invalid.output.contains("Unknown command"))
}

@Test
func commandRouterIncludesGroupCommand() {
  let router = CommandRouter()
  #expect(router.specs.contains { $0.name == "group" })
}

private func runIMsgProcess(
  _ arguments: [String],
  environment extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
  let executable = try imsgExecutableURL()
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  var environment = ProcessInfo.processInfo.environment
  for (key, value) in extraEnvironment {
    environment[key] = value
  }
  process.environment = environment

  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  output.fileHandleForWriting.closeFile()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func imsgExecutableURL() throws -> URL {
  let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let candidates = [
    cwd.appendingPathComponent(".build/debug/imsg"),
    cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/imsg"),
    cwd.appendingPathComponent(".build/x86_64-apple-macosx/debug/imsg"),
  ]
  for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
    return candidate
  }
  throw CocoaError(.fileNoSuchFile)
}

@Test
func commandRouterIncludesCompletionsCommand() {
  let router = CommandRouter()
  #expect(router.specs.contains { $0.name == "completions" })
}

@Test
func completionsGenerateAllFormats() throws {
  let specs = CommandRouter().specs
  let bash = try CompletionGenerator.generate(shell: "bash", rootName: "imsg", specs: specs)
  let zsh = try CompletionGenerator.generate(shell: "zsh", rootName: "imsg", specs: specs)
  let fish = try CompletionGenerator.generate(shell: "fish", rootName: "imsg", specs: specs)
  let llm = try CompletionGenerator.generate(shell: "llm", rootName: "imsg", specs: specs)

  #expect(bash.contains("complete -F _imsg imsg"))
  #expect(zsh.contains("#compdef imsg"))
  #expect(fish.contains("complete -c imsg"))
  #expect(llm.contains("# imsg CLI Reference"))
}

@Test
func completionsIncludeCurrentCommandsAndOptions() throws {
  let specs = CommandRouter().specs
  let output = try CompletionGenerator.generate(shell: "llm", rootName: "imsg", specs: specs)
  for spec in specs {
    #expect(output.contains("### \(spec.name)"))
  }
  #expect(output.contains("--convert-attachments"))
  #expect(output.contains("--reaction, -r <value>"))
}

@Test
func completionsRejectUnknownShell() {
  do {
    _ = try CompletionGenerator.generate(shell: "powershell", rootName: "imsg", specs: [])
    #expect(Bool(false))
  } catch let error as CompletionError {
    #expect(error.description.contains("Unknown shell"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func completionsCommandRunsThroughRouter() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "completions", "fish"])
  }
  #expect(status == 0)
  #expect(output.contains("complete -c imsg"))
}
