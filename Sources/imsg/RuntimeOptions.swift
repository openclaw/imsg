import Commander

struct RuntimeOptions: Sendable {
  let jsonOutput: Bool
  let verbose: Bool
  let logLevel: String?
  /// When true, the CLI refuses any write or mutation. Set by the global
  /// `--read-only` flag or the `IMSG_READ_ONLY` environment variable.
  let readOnly: Bool
  /// When true, texted security/verification codes (2FA, OTP) are redacted
  /// from message text before it is rendered or serialized. Set by the
  /// global `--redact-codes` flag.
  let redactCodes: Bool

  init(parsedValues: ParsedValues, readOnly: Bool = false, redactCodes: Bool = false) {
    self.jsonOutput = parsedValues.flags.contains("jsonOutput")
    self.verbose = parsedValues.flags.contains("verbose")
    self.logLevel = parsedValues.options["logLevel"]?.last
    self.readOnly =
      readOnly || parsedValues.flags.contains(CommandSignatures.readOnlyFlagLabel)
    self.redactCodes =
      redactCodes || parsedValues.flags.contains(CommandSignatures.redactCodesFlagLabel)
  }
}
