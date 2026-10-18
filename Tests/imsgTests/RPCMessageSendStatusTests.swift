import Foundation
import Testing

@testable import IMsgCore
@testable import IMsgRPC

private func sendStatusInt64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcMessageSendStatusReturnsNormalizedStatus() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  try addSendStatusColumns(to: store)
  _ = try store.withConnection { db in
    try db.run(
      """
      UPDATE message
      SET guid = 'delivered-guid',
          error = 0,
          date_delivered = ?,
          date_read = 0,
          is_sent = 1,
          is_delivered = 1,
          is_finished = 1,
          is_delayed = 0,
          is_prepared = 0,
          is_pending_satellite_send = 0,
          was_downgraded = 0
      WHERE ROWID = 5
      """,
      CommandTestDatabase.appleEpoch(Date(timeIntervalSince1970: 1_779_348_870))
    )
  }
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"send-status","method":"message.send_status","params":{"guid":"delivered-guid"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["guid"] as? String == "delivered-guid")
  #expect(result?["send_state"] as? String == "delivered")
  #expect(result?["service"] as? String == "iMessage")
  #expect(result?["checked_at"] as? String != nil)
  #expect(result?["delivered_at"] as? String != nil)
  let fields = result?["status_fields"] as? [String: Any]
  #expect(fields?["is_sent"] as? Bool == true)
  #expect(fields?["is_delivered"] as? Bool == true)
  #expect(sendStatusInt64Value(fields?["error"]) == 0)
  #expect(fields?["date_delivered"] as? String != nil)
}

@Test
func rpcMessageSendStatusMissingRowReturnsPending() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"send-status","method":"message.send_status","params":{"guid":"missing-guid"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["guid"] as? String == "missing-guid")
  #expect(result?["send_state"] as? String == "pending")
  #expect(result?["service"] is NSNull)
  #expect(result?["checked_at"] as? String != nil)
  #expect(result?["status_fields"] is NSNull)
}

@Test
func rpcMessageSendStatusRejectsMissingGuid() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"send-status","method":"message.send_status","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(sendStatusInt64Value(error?["code"]) == -32602)
}

private func addSendStatusColumns(to store: MessageStore) throws {
  try store.withConnection { db in
    try db.run("ALTER TABLE message ADD COLUMN guid TEXT")
    try db.run("ALTER TABLE message ADD COLUMN error INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN date_delivered INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN date_read INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_sent INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_delivered INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_finished INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_delayed INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_prepared INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN is_pending_satellite_send INTEGER")
    try db.run("ALTER TABLE message ADD COLUMN was_downgraded INTEGER")
  }
}
