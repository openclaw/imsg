import Foundation
import Testing

@testable import imsg

@Test
func chatsUnreadOnlyFlagFiltersToUnreadChats() async throws {
  let dbPath = try UnreadStateCommandTestDatabase.makePath()
  let router = CommandRouter()

  let (allOutput, _) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "chats", "--db", dbPath, "--json"])
  }
  let allChats = allOutput.split(separator: "\n").map { line in
    try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  }
  #expect(allChats.count == 2)

  let (unreadOutput, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "chats", "--db", dbPath, "--unread-only", "--json"])
  }
  #expect(status == 0)
  let unreadChats = unreadOutput.split(separator: "\n").map { line in
    try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  }
  #expect(unreadChats.count == 1)
  #expect(unreadChats.first?["id"] as? Int == 1)
  #expect(unreadChats.first?["unread_count"] as? Int == 1)
}

@Test
func chatsUnreadOnlyRejectsDatabaseWithoutReadState() throws {
  let dbPath = try CommandTestDatabase.makePath()
  let result = try runIMsgProcess(["chats", "--db", dbPath, "--unread-only", "--json"])
  #expect(result.status == 1)
  #expect(result.output.isEmpty)
  #expect(result.error.contains("Unread filtering is unavailable"))
}
