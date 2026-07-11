import Commander
import Testing

@testable import imsg

private let validationRichLinkFixture = PreparedRichLinkPreview(
  originalURL: "https://imsg.sh",
  resolvedURL: "https://imsg.sh/",
  title: "imsg",
  image: nil
)

@Test
func sendRichURLRejectsModifiersAndSMSBeforePreparation() async throws {
  let cases: [(options: [String: [String]], flags: Set<String>)] = [
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "text": ["caption"]], []),
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "file": ["pic.png"]], []),
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "effect": ["loud"]], []),
    (
      ["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "subject": ["subject"]],
      []
    ),
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "replyTo": ["guid"]], []),
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"], "part": ["1"]], []),
    (
      [
        "chat": ["iMessage;-;+15551234567"],
        "url": ["https://imsg.sh"],
        "format": ["[{\"start\":0,\"length\":4,\"styles\":[\"bold\"]}]"],
      ],
      []
    ),
    (
      [
        "chat": ["iMessage;-;+15551234567"],
        "url": ["https://imsg.sh"],
        "formatFile": ["/tmp/rich-link-format.json"],
      ],
      []
    ),
    (["chat": ["iMessage;-;+15551234567"], "url": ["https://imsg.sh"]], ["noDDScan"]),
    (["chat": ["SMS;-;+15551234567"], "url": ["https://imsg.sh"]], []),
  ]

  for testCase in cases {
    let values = ParsedValues(
      positional: [],
      options: testCase.options,
      flags: testCase.flags
    )
    let runtime = RuntimeOptions(parsedValues: values)
    var prepared = false
    var invoked = false
    do {
      try await SendRichCommand.run(
        values: values,
        runtime: runtime,
        invokeBridge: { _, _ in
          invoked = true
          return [:]
        },
        prepareRichLink: { _ in
          prepared = true
          return validationRichLinkFixture
        }
      )
      Issue.record("expected rich-link option validation to fail")
    } catch is ParsedValuesError {
      // Expected.
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(!prepared)
    #expect(!invoked)
  }
}
