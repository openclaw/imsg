import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcSendEnablesSMSFallbackForAutoTextDirectSend() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3sms","method":"send","params":{"to":"+15551234567","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.service == .auto)
  #expect(captured?.allowSMSFallback == true)
}

@Test
func rpcSendCanDisableOtherwiseEligibleSMSFallbackWithoutChangingAutoService() async throws {
  for key in ["allow_sms_fallback", "allowSMSFallback"] {
    let store = try CommandTestDatabase.makeStoreForRPC()
    let output = TestRPCOutput()
    var captured: MessageSendOptions?
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      sendMessage: {
        captured = $0
        return $0
      },
      resolveSentMessage: resolvedSentMessageFixture
    )

    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":\"no-fallback\",\"method\":\"send\","
        + "\"params\":{\"to\":\"+15551234567\",\"text\":\"yo\",\"\(key)\":false}}"
    )

    #expect(captured?.service == .auto)
    #expect(captured?.allowSMSFallback == false)
    #expect(output.errors.isEmpty)
  }
}

@Test
func rpcSendAutoUsesLocalSMSHistoryForAttachmentSend() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  try store.withConnection { db in
    try db.run("ALTER TABLE handle ADD COLUMN service TEXT")
    try db.run("INSERT INTO handle(ROWID, id, service) VALUES (10, '+15551234567', 'SMS')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (10, 10, 'sms history', ?, 0, 'SMS')
      """,
      CommandTestDatabase.appleEpoch(Date())
    )
  }
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3smsfile","method":"send","params":{"to":"+15551234567","file":"/tmp/photo.jpg"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.service == .sms)
  #expect(captured?.allowSMSFallback == false)
}

@Test
func rpcSendAutoDetectionUsesRegionNormalizedRecipient() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  try store.withConnection { db in
    try db.run("ALTER TABLE handle ADD COLUMN service TEXT")
    try db.run("INSERT INTO handle(ROWID, id, service) VALUES (44, '+447700900000', 'SMS')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (44, 44, 'sms history', ?, 0, 'SMS')
      """,
      CommandTestDatabase.appleEpoch(Date())
    )
  }
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: { _, _, _, _ in nil }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3region","method":"send","params":{"to":"07700 900000","file":"/tmp/photo.jpg","region":"GB"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.service == .sms)
  #expect(captured?.allowSMSFallback == false)
}

@Test
func rpcSendDisablesSMSFallbackForExplicitService() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in
      captured = options
      return options
    },
    resolveSentMessage: resolvedSentMessageFixture
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3nosms","method":"send","params":{"to":"+15551234567","text":"yo","service":"imessage"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.service == .imessage)
  #expect(captured?.allowSMSFallback == false)
}
