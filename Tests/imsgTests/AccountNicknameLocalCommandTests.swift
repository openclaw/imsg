import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func accountSeedStore() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      chat_identifier TEXT,
      guid TEXT,
      display_name TEXT,
      service_name TEXT,
      account_id TEXT,
      account_login TEXT
    );
    """
  )
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, account_id, account_login)
    VALUES
      (1, '+123', 'iMessage;+;a', 'iMessage;+;me@icloud.com', 'me@icloud.com'),
      (2, '+456', 'iMessage;+;b', 'iMessage;+;me@icloud.com', 'me@icloud.com'),
      (3, '+789', 'iMessage;+;c', 'iMessage;+;other@icloud.com', 'other@icloud.com')
    """
  )
  return try MessageStore(connection: db, path: ":memory:")
}

@Test
func accountLocalListsAccountsRankedByChatCount() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try accountSeedStore()
  let (output, _) = try await StdoutCapture.capture {
    try await AccountCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store }
    )
  }
  #expect(output.contains("accounts (source=local):"))
  #expect(output.contains("me@icloud.com (chats=2)"))
  #expect(output.contains("other@icloud.com (chats=1)"))
}

@Test
func accountLocalEmitsJsonArray() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["local", "jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try accountSeedStore()
  let (output, _) = try await StdoutCapture.capture {
    try await AccountCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["source"] as? String == "local")
  let accounts = try #require(payload["accounts"] as? [[String: Any]])
  #expect(accounts.count == 2)
  #expect(accounts.first?["login"] as? String == "me@icloud.com")
  #expect((accounts.first?["chat_count"] as? NSNumber)?.intValue == 2)
}

@Test
func accountLocalReportsNoneWhenEmpty() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await AccountCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in try emptyChatStore() },
      localAccounts: { _ in [] }
    )
  }
  #expect(output.contains("(none found in local history)"))
}

@Test
func nicknameLocalReturnsAddressBookName() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["address": ["+15551234567"]],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(names: ["+15551234567": "Alice Smith"])
  let (output, _) = try await StdoutCapture.capture {
    try await NicknameCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { _ in resolver }
    )
  }
  #expect(output.contains("local_contact_name: Alice Smith"))
  #expect(output.contains("source=local-addressbook"))
}

@Test
func nicknameLocalJsonReportsFoundFalseWhenUnknown() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["address": ["+15559998888"]],
    flags: ["local", "jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let resolver = MockContactResolver(names: [:], contactsUnavailable: true)
  let (output, _) = try await StdoutCapture.capture {
    try await NicknameCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { _ in resolver }
    )
  }
  let payload = try jsonObject(from: output)
  #expect(payload["address"] as? String == "+15559998888")
  #expect(payload["found"] as? Bool == false)
  #expect(payload["source"] as? String == "local-addressbook")
  #expect(payload["contacts_unavailable"] as? Bool == true)
}

@Test
func nicknameLocalRequiresAddress() async {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["local"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await NicknameCommand.run(
      values: values,
      runtime: runtime,
      contactResolverFactory: { _ in MockContactResolver(names: [:]) }
    )
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

private func emptyChatStore() throws -> MessageStore {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      account_id TEXT,
      account_login TEXT
    );
    """
  )
  return try MessageStore(connection: db, path: ":memory:")
}

private func jsonObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
