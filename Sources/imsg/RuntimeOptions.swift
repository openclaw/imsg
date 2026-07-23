import Commander

struct RuntimeOptions: Sendable {
  let jsonOutput: Bool
  let verbose: Bool
  let logLevel: String?
  /// When true, the CLI refuses any write or mutation. Set by the global
  /// `--read-only` flag or the `IMSG_READ_ONLY` environment variable.
  let readOnly: Bool

  init(parsedValues: ParsedValues, readOnly: Bool = false) {
    self.jsonOutput = parsedValues.flags.contains("jsonOutput")
    self.verbose = parsedValues.flags.contains("verbose")
    self.logLevel = parsedValues.options["logLevel"]?.last
    self.readOnly =
      readOnly || parsedValues.flags.contains(CommandSignatures.readOnlyFlagLabel)
  }
}
