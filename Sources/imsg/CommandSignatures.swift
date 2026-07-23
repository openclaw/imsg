import Commander
import IMsgCore

enum CommandSignatures {
  static func baseOptions() -> [OptionDefinition] {
    [
      .make(
        label: "db",
        names: [.long("db")],
        help: "Path to chat.db (defaults to ~/Library/Messages/chat.db)"
      )
    ]
  }

  /// Global `--read-only` flag. Registered on every command so it parses in the
  /// usual position (`imsg <cmd> --read-only`) and shows up in `--help`. It is
  /// also detected directly from argv / `IMSG_READ_ONLY` by `CommandRouter`, so
  /// enforcement does not depend on Commander parsing it.
  static let readOnlyFlagLabel = "readOnly"
  static let readOnlyFlagName = "--read-only"

  static func readOnlyFlag() -> FlagDefinition {
    .make(
      label: readOnlyFlagLabel,
      names: [.long("read-only")],
      help: "Refuse any write or mutation; only read operations are permitted"
    )
  }

  static func withRuntimeFlags(_ signature: CommandSignature) -> CommandSignature {
    let base = signature.withStandardRuntimeFlags()
    return CommandSignature(
      arguments: base.arguments,
      options: base.options,
      flags: base.flags + [readOnlyFlag()],
      optionGroups: base.optionGroups
    )
  }
}
