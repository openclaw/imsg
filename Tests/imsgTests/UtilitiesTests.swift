import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func durationParserHandlesUnits() {
  #expect(DurationParser.parse("250ms") == 0.25)
  #expect(DurationParser.parse("2s") == 2)
  #expect(DurationParser.parse("3m") == 180)
  #expect(DurationParser.parse("1h") == 3600)
  #expect(DurationParser.parse("5") == 5)
  #expect(DurationParser.parse("bad") == nil)
}

@Test
func attachmentDisplayPrefersTransferName() {
  let meta = AttachmentMeta(
    filename: "file.dat",
    transferName: "friendly.dat",
    uti: "",
    mimeType: "",
    totalBytes: 0,
    isSticker: false,
    originalPath: "",
    missing: false
  )
  #expect(displayName(for: meta) == "friendly.dat")
  let fallback = AttachmentMeta(
    filename: "file.dat",
    transferName: "",
    uti: "",
    mimeType: "",
    totalBytes: 0,
    isSticker: false,
    originalPath: "",
    missing: false
  )
  #expect(displayName(for: fallback) == "file.dat")
  let unknown = AttachmentMeta(
    filename: "",
    transferName: "",
    uti: "",
    mimeType: "",
    totalBytes: 0,
    isSticker: false,
    originalPath: "",
    missing: false
  )
  #expect(displayName(for: unknown) == "(unknown)")
  #expect(pluralSuffix(for: 1) == "")
  #expect(pluralSuffix(for: 2) == "s")
}

@Test
func jsonLinesPrintsSingleLineJSON() throws {
  let line = try JSONLines.encode(["status": "ok"])
  let data = line.data(using: .utf8)!
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(decoded?["status"] as? String == "ok")
}

@Test
func jsonLinesEscapesEmbeddedNewlines() throws {
  let line = try JSONLines.encode(["text": "Line 1\nLine 2"])
  #expect(line.contains("\n") == false)
  #expect(line.contains(#"\n"#) == true)

  let data = line.data(using: .utf8)!
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(decoded?["text"] as? String == "Line 1\nLine 2")
}

@Test
func jsonObjectOutputEscapesEmbeddedNewlines() async throws {
  let captured = try await StdoutCapture.capture {
    try JSONLines.printObject(["text": "Line 1\nLine 2"])
  }

  #expect(captured.output.filter { $0 == "\n" }.count == 1)
  #expect(captured.output.contains(#"\n"#) == true)

  let line = captured.output.trimmingCharacters(in: .newlines)
  let data = line.data(using: .utf8)!
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(decoded?["text"] as? String == "Line 1\nLine 2")
}

@Test
func rpcWriterEscapesEmbeddedNewlinesInNotifications() async throws {
  let captured = await StdoutCapture.capture {
    RPCWriter().sendNotification(
      method: "message",
      params: ["message": ["text": "Line 1\nLine 2"]]
    )
  }

  #expect(captured.output.filter { $0 == "\n" }.count == 1)
  #expect(captured.output.contains(#"\n"#) == true)

  let line = captured.output.trimmingCharacters(in: .newlines)
  let data = line.data(using: .utf8)!
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let params = decoded?["params"] as? [String: Any]
  let message = params?["message"] as? [String: Any]
  #expect(message?["text"] as? String == "Line 1\nLine 2")
}

@Test
func outputModelsEncodeExpectedKeys() throws {
  let chat = Chat(
    id: 1, identifier: "+123", name: "Test", service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0))
  let chatPayload = ChatPayload(chat: chat)
  let chatData = try JSONEncoder().encode(chatPayload)
  let chatObject = try JSONSerialization.jsonObject(with: chatData) as? [String: Any]
  #expect(chatObject?["last_message_at"] != nil)

  let message = Message(
    rowID: 7,
    chatID: 1,
    sender: "+123",
    text: "hi",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-guid-7",
    replyToGUID: "msg-guid-1",
    threadOriginatorGUID: "thread-guid-7",
    threadOriginatorPart: "0:0:2",
    destinationCallerID: "me@icloud.com"
  )
  let attachment = AttachmentMeta(
    filename: "file.dat",
    transferName: "",
    uti: "public.data",
    mimeType: "application/octet-stream",
    totalBytes: 10,
    isSticker: false,
    originalPath: "/tmp/file.dat",
    convertedPath: "/tmp/file.m4a",
    convertedMimeType: "audio/mp4",
    missing: false
  )
  let reaction = Reaction(
    rowID: 99,
    reactionType: .like,
    sender: "+123",
    isFromMe: true,
    date: Date(timeIntervalSince1970: 2),
    associatedMessageID: 7
  )
  let messagePayload = MessagePayload(
    message: message, attachments: [attachment], reactions: [reaction])
  let messageData = try JSONEncoder().encode(messagePayload)
  let messageObject = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
  #expect(messageObject?["chat_id"] as? Int64 == 1)
  #expect(messageObject?["guid"] as? String == "msg-guid-7")
  #expect(messageObject?["reply_to_guid"] as? String == "msg-guid-1")
  #expect(messageObject?["destination_caller_id"] as? String == "me@icloud.com")
  #expect(messageObject?["thread_originator_guid"] as? String == "thread-guid-7")
  #expect(messageObject?["thread_originator_part"] as? String == "0:0:2")
  #expect(messageObject?["created_at"] != nil)

  let attachmentPayload = AttachmentPayload(meta: attachment)
  let attachmentData = try JSONEncoder().encode(attachmentPayload)
  let attachmentObject = try JSONSerialization.jsonObject(with: attachmentData) as? [String: Any]
  #expect(attachmentObject?["transfer_name"] as? String == "")
  #expect(attachmentObject?["mime_type"] as? String == "application/octet-stream")
  #expect(attachmentObject?["converted_path"] as? String == "/tmp/file.m4a")
  #expect(attachmentObject?["converted_mime_type"] as? String == "audio/mp4")
}

@Test
func cliISO8601MatchesFoundationFormatterConcurrently() async {
  let dates = [
    Date(timeIntervalSince1970: 0),
    Date(timeIntervalSince1970: 1_752_000_000.123),
    Date(timeIntervalSince1970: -0.001),
    Date(timeIntervalSince1970: 1_752_000_000.999_999),
  ]
  let oracle = ISO8601DateFormatter()
  oracle.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let expected = dates.map { oracle.string(from: $0) }

  let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
    for _ in 0..<16 {
      group.addTask {
        (0..<100).flatMap { _ in dates.map(CLIISO8601.format) }
      }
    }
    var results: [[String]] = []
    for await result in group {
      results.append(result)
    }
    return results
  }

  let repeatedExpected = Array(repeating: expected, count: 100).flatMap { $0 }
  #expect(results.allSatisfy { $0 == repeatedExpected })
}

@Test
func parsedValuesHelpers() throws {
  let values = ParsedValues(
    positional: ["first"],
    options: ["limit": ["5", "9"], "name": ["bob"], "logLevel": ["debug"]],
    flags: ["jsonOutput", "verbose"]
  )
  #expect(values.flag("jsonOutput") == true)
  #expect(values.option("name") == "bob")
  #expect(values.optionValues("limit").count == 2)
  #expect(values.optionInt("limit") == 9)
  #expect(values.optionInt64("limit") == 9)
  #expect(values.argument(0) == "first")
  do {
    _ = try values.optionRequired("missing")
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  }

  let runtime = RuntimeOptions(parsedValues: values)
  #expect(runtime.jsonOutput == true)
  #expect(runtime.verbose == true)
  #expect(runtime.logLevel == "debug")
}
