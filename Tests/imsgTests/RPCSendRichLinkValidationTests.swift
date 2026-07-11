import Testing

@testable import IMsgCore
@testable import imsg

private let rpcValidationRichLinkFixture = PreparedRichLinkPreview(
  originalURL: "https://imsg.sh",
  resolvedURL: "https://imsg.sh/",
  title: "imsg",
  image: nil
)

@Test
func rpcSendRichURLRejectsInvalidTypesAndModifiersBeforePreparation() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let requests = [
    #"{"chat_id":1,"url":42}"#,
    #"{"chat_id":null,"url":"https://imsg.sh"}"#,
    #"{"chat_id":true,"url":"https://imsg.sh"}"#,
    #"{"chat_id":[],"url":"https://imsg.sh"}"#,
    #"{"chat_id":1.5,"url":"https://imsg.sh"}"#,
    #"{"chat_id":1.0,"url":"https://imsg.sh"}"#,
    #"{"chat_id":1e0,"url":"https://imsg.sh"}"#,
    #"{"chat_id":0,"url":"https://imsg.sh"}"#,
    #"{"chat_id":-1,"url":"https://imsg.sh"}"#,
    #"{"chat_id":9223372036854775808,"url":"https://imsg.sh"}"#,
    #"{"chat_id":"1","url":"https://imsg.sh"}"#,
    #"{"chat_id":1,"chat_guid":"iMessage;+;chat123","url":"https://imsg.sh"}"#,
    #"{"chat_identifier":123,"url":"https://imsg.sh"}"#,
    #"{"chat_identifier":"","url":"https://imsg.sh"}"#,
    #"{"chat_guid":false,"url":"https://imsg.sh"}"#,
    #"{"chat_guid":"","url":"https://imsg.sh"}"#,
    #"{"chat_guid":"iMessage;-;missing","url":"https://imsg.sh"}"#,
    #"{"chat_id":1,"link":"https://imsg.sh"}"#,
    #"{"chat_id":1,"rich_link_url":"https://imsg.sh"}"#,
    #"{"chat_id":1,"rich_link":true}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","text":"caption"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","message":"caption"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","file":"/tmp/file"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","path":"/tmp/file"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","effect":"confetti"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","effect_id":"confetti"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","effectId":"confetti"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","subject":"subject"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","rich_link":true}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","richLink":true}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","reply_to":"guid"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","replyTo":"guid"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","reply_to_guid":"guid"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","message_guid":"guid"}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","part_index":1}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","partIndex":1}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","dd_scan":false}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","ddScan":false}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","text_formatting":[]}"#,
    #"{"chat_id":1,"url":"https://imsg.sh","textFormatting":[]}"#,
  ]

  for (index, params) in requests.enumerated() {
    let output = TestRPCOutput()
    var prepared = false
    var invoked = false
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { _, _ in
        invoked = true
        return [:]
      },
      prepareRichLink: { _ in
        prepared = true
        return rpcValidationRichLinkFixture
      }
    )
    await server.handleLineForTesting(
      "{\"jsonrpc\":\"2.0\",\"id\":\"invalid-\(index)\","
        + "\"method\":\"send.rich\",\"params\":\(params)}"
    )
    let error = output.errors.first?["error"] as? [String: Any]
    #expect((error?["code"] as? Int) == -32602)
    #expect(!prepared)
    #expect(!invoked)
  }
}
