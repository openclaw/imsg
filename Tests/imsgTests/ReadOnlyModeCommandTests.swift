import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

// MARK: - RuntimeOptions

@Test
func runtimeOptionsReadOnlyDefaultsFalse() {
  let values = ParsedValues(positional: [], options: [:], flags: [])
  let runtime = RuntimeOptions(parsedValues: values)
  #expect(runtime.readOnly == false)
}

@Test
func runtimeOptionsReadOnlyFromExplicitFlag() {
  let values = ParsedValues(positional: [], options: [:], flags: [])
  let runtime = RuntimeOptions(parsedValues: values, readOnly: true)
  #expect(runtime.readOnly == true)
}

@Test
func runtimeOptionsReadOnlyFromParsedFlag() {
  let values = ParsedValues(
    positional: [], options: [:], flags: [CommandSignatures.readOnlyFlagLabel])
  let runtime = RuntimeOptions(parsedValues: values)
  #expect(runtime.readOnly == true)
}

// MARK: - Env parsing

@Test
func readOnlyEnvValueTruthy() {
  for raw in ["1", "true", "TRUE", "Yes", "on", " on "] {
    #expect(CommandRouter.readOnlyEnvValue(raw) == true, "expected truthy for \(raw)")
  }
}

@Test
func readOnlyEnvValueFalsy() {
  for raw in [nil, "", "0", "false", "no", "off", "banana"] {
    #expect(CommandRouter.readOnlyEnvValue(raw) == false, "expected falsy for \(raw ?? "nil")")
  }
}

// MARK: - argv extraction

@Test
func extractReadOnlyDropsLeadingFlagBeforeSubcommand() {
  let (readOnly, argv) = CommandRouter.extractReadOnly(
    ["imsg", "--read-only", "send", "--to", "x"])
  #expect(readOnly == true)
  // Leading global flag is removed so Commander can resolve the subcommand.
  #expect(argv == ["imsg", "send", "--to", "x"])
}

@Test
func extractReadOnlyKeepsFlagAfterSubcommand() {
  let (readOnly, argv) = CommandRouter.extractReadOnly(["imsg", "send", "--read-only"])
  // Post-subcommand flag is left for Commander to parse; RuntimeOptions folds it in.
  #expect(argv == ["imsg", "send", "--read-only"])
  // extractReadOnly itself only reports env / leading-flag state here.
  #expect(readOnly == false)
}

@Test
func extractReadOnlyLeavesPlainArgvUnchanged() {
  let (readOnly, argv) = CommandRouter.extractReadOnly(["imsg", "chats", "--json"])
  #expect(readOnly == false)
  #expect(argv == ["imsg", "chats", "--json"])
}

// MARK: - Command classification

@Test
func writeCommandsReportMutating() {
  let anyValues = ParsedValues(positional: [], options: [:], flags: [])
  #expect(SendCommand.spec.isMutating(for: anyValues) == true)
  #expect(ReactCommand.spec.isMutating(for: anyValues) == true)
  #expect(ReadCommand.spec.isMutating(for: anyValues) == true)
  #expect(TypingCommand.spec.isMutating(for: anyValues) == true)
  #expect(ChatMarkCommand.spec.isMutating(for: anyValues) == true)
}

@Test
func readCommandsReportNonMutating() {
  let anyValues = ParsedValues(positional: [], options: [:], flags: [])
  #expect(ChatsCommand.spec.isMutating(for: anyValues) == false)
  #expect(HistoryCommand.spec.isMutating(for: anyValues) == false)
  #expect(StatsCommand.spec.isMutating(for: anyValues) == false)
  #expect(WatchCommand.spec.isMutating(for: anyValues) == false)
  #expect(SearchCommand.spec.isMutating(for: anyValues) == false)
  #expect(StatusCommand.spec.isMutating(for: anyValues) == false)
  #expect(RpcCommand.spec.isMutating(for: anyValues) == false)
  #expect(LaunchCommand.spec.isMutating(for: anyValues) == false)
}

@Test
func namePhotoIsConditionallyMutating() {
  let statusValues = ParsedValues(positional: ["status"], options: [:], flags: [])
  let shareValues = ParsedValues(positional: ["share"], options: [:], flags: [])
  let emptyValues = ParsedValues(positional: [], options: [:], flags: [])
  let garbageValues = ParsedValues(positional: ["bogus"], options: [:], flags: [])
  #expect(NamePhotoCommand.spec.isMutating(for: statusValues) == false)
  #expect(NamePhotoCommand.spec.isMutating(for: shareValues) == true)
  // Fail-closed: an unrecognized or missing action is treated as mutating,
  // not silently allowed through.
  #expect(NamePhotoCommand.spec.isMutating(for: emptyValues) == true)
  #expect(NamePhotoCommand.spec.isMutating(for: garbageValues) == true)
}

// MARK: - Router gating (end to end)

@Test
func routerBlocksWriteCommandWithLeadingReadOnlyFlag() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "--read-only", "send", "--to", "+15551234567", "--text", "hi"])
  }
  #expect(status == CommandRouter.readOnlyExitCode)
  #expect(output.contains("read-only mode"))
  #expect(output.contains("'send'"))
}

@Test
func routerBlocksWriteCommandWithTrailingReadOnlyFlag() async {
  let router = CommandRouter()
  let (_, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "send", "--to", "+15551234567", "--text", "hi", "--read-only"])
  }
  #expect(status == CommandRouter.readOnlyExitCode)
}

@Test
func routerBlockedWriteEmitsJSONWhenRequested() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "--read-only", "send", "--to", "+1", "--text", "hi", "--json"])
  }
  #expect(status == CommandRouter.readOnlyExitCode)
  // Matches the existing `{"success": false, "error": "..."}` shape used by
  // other --json command failures (BridgeOutput.emitError), with additive
  // fields for programmatic detection.
  #expect(output.contains("\"success\":false"))
  #expect(output.contains("\"error_code\":\"read_only\""))
  #expect(output.contains("\"command\":\"send\""))
}
