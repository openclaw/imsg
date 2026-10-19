import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test(arguments: ["chats", "history"], [false, true])
func readCommandsSkipContactsWhenRequested(command: String, json: Bool) async throws {
  let path = try CommandTestDatabase.makePathDirectChat()
  let values = ParsedValues(
    positional: [], options: ["db": [path], "chatID": ["1"]],
    flags: json ? ["noContacts", "jsonOutput"] : ["noContacts"])
  var factoryCalls = 0
  let factory: () async -> any ContactResolving = {
    factoryCalls += 1
    return MockContactResolver(names: ["+123": "Fixture Contact"])
  }
  let (output, _) = try await StdoutCapture.capture {
    if command == "chats" {
      try await ChatsCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        contactResolverFactory: factory)
    } else {
      try await HistoryCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        contactResolverFactory: factory)
    }
  }
  #expect(factoryCalls == 0)
  #expect(!output.contains("Fixture Contact"))
  #expect(output.contains("+123"))
}

@Test(arguments: ["chats", "history"])
func readCommandsParseNoContactsFlag(command: String) throws {
  let spec = try #require(CommandRouter().specs.first { $0.name == command })
  let values = try CommandParser(signature: spec.signature).parse(arguments: ["--no-contacts"])
  #expect(values.flag("noContacts"))
}
