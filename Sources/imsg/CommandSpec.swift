import Commander

struct CommandSpec: Sendable {
  let name: String
  let abstract: String
  let discussion: String?
  let signature: CommandSignature
  let usageExamples: [String]
  let run: @Sendable (ParsedValues, RuntimeOptions) async throws -> Void

  var descriptor: CommandDescriptor {
    CommandDescriptor(
      name: name,
      abstract: abstract,
      discussion: discussion,
      signature: signature
    )
  }
}
