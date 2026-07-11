import Foundation
import Testing

@testable import imsg

@Test
func chatBackgroundStatusEmitsReadOnlyJSON() async throws {
  let path = try ChatBackgroundCommandTestDatabase.makePath()
  let router = CommandRouter()

  let (output, status) = await StdoutCapture.capture {
    await router.run(
      argv: ["imsg", "chat-background", "status", "--chat-id", "1", "--db", path, "--json"]
    )
  }

  #expect(status == 0)
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  #expect(payload["chat_id"] as? Int == 1)
  #expect(payload["background_set"] as? Bool == true)
  #expect(payload["background_channel_guid"] as? String == "channel-123")
  #expect(payload["cache_exists"] as? Bool == true)
  #expect(payload["watch_background_exists"] as? Bool == false)
  #expect(payload["object_id"] == nil)
  let event = payload["latest_event"] as? [String: Any]
  #expect(event?["action"] as? String == "set")
}

@Test
func chatBackgroundStatusEmitsPlainOutput() async throws {
  let path = try ChatBackgroundCommandTestDatabase.makePath()
  let router = CommandRouter()

  let (output, status) = await StdoutCapture.capture {
    await router.run(
      argv: ["imsg", "chat-background", "status", "--chat-id", "1", "--db", path]
    )
  }

  #expect(status == 0)
  #expect(output.contains("chat-background: set"))
  #expect(output.contains("background_channel_guid: channel-123"))
  #expect(output.contains("latest_event: set row=1"))
}

@Test
func chatBackgroundRejectsMutationsAndInvalidTargets() async throws {
  let path = try ChatBackgroundCommandTestDatabase.makePath()
  let router = CommandRouter()

  for arguments in [
    ["set", "--chat-id", "1"],
    ["clear", "--chat-id", "1"],
    ["status", "--chat-id", "0"],
    ["status", "--chat-id", "not-a-number"],
    ["status", "--chat-id", "999"],
  ] {
    let (_, status) = await StdoutCapture.capture {
      await router.run(argv: ["imsg", "chat-background"] + arguments + ["--db", path])
    }
    #expect(status == 1)
  }
}

@Test
func chatBackgroundHelpAdvertisesStatusOnly() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: ["imsg", "chat-background", "--help"])
  }

  #expect(status == 0)
  #expect(output.contains("status"))
  #expect(!output.contains("status|clear|set"))
  #expect(!output.contains("--file"))
  #expect(!output.contains("--chat "))
}
