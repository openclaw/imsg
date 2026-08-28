import Foundation
import Testing

@testable import IMsgCore

#if os(macOS)
  // Execute the production AppleScript control flow, replacing only Messages
  // operations so the regression tests never dispatch a real message.
  private func runDirectChatScript(
    lookupError: Int = -1728,
    sendError: Int = 0,
    account: String = "test-account",
    text: String = "hello",
    attachment: Bool = false,
    accountError: Int = 0,
    smsAccount: Bool = false
  ) throws -> String {
    var source = ""
    var arguments: [String] = []
    try MessageSender(runner: {
      source = $0
      arguments = $1
    }).send(
      MessageSendOptions(
        recipient: "friend@example.com", text: text, service: .imessage,
        chatGUID: "iMessage;-;friend@example.com", allowSMSFallback: false))
    arguments = Array(arguments.prefix(7)) + [account, "friend@example.com", "imessage"]
    if attachment {
      arguments[3] = "/tmp/synthetic-attachment"
      arguments[4] = "1"
    }
    let substitutions = [
      ("tell application \"Messages\"", "using terms from application \"Messages\""),
      ("end tell", "end using terms from"),
      ("set targetChat to get chat id chatId", "set targetChat to my lookupChat()"),
      ("set targetChat to chat id chatId", "set targetChat to my lookupChat()"),
      ("get account id directAccountID", "my lookupAccount()"),
      ("service type of targetAccount", "my accountService()"),
      ("get buddy directRecipient of targetAccount", "\"participant\""),
      ("send theMessage to targetChat", "my dispatchMessage(targetChat)"),
      ("send theFile to targetChat", "my dispatchMessage(targetChat)"),
      ("POSIX file theFilePath as alias", "theFilePath"),
    ]
    for (original, replacement) in substitutions {
      source = source.replacingOccurrences(of: original, with: replacement)
    }
    source = source.replacingOccurrences(
      of: "& tab & \"0\"", with: "& tab & \"0\" & \"|\" & dispatchCount & \"|\" & targetKind")
    source += """

      property dispatchCount : 0
      property targetKind : "none"
      on lookupChat()
          if \(lookupError) is not 0 then error number \(lookupError)
          return "chat"
      end lookupChat
      on lookupAccount()
          if \(accountError) is not 0 then error number \(accountError)
          return "account"
      end lookupAccount
      on accountService()
          using terms from application "Messages"
              return \(smsAccount ? "SMS" : "iMessage")
          end using terms from
      end accountService
      on dispatchMessage(targetValue)
          set dispatchCount to dispatchCount + 1
          set targetKind to targetValue
          if \(sendError) is not 0 then error number \(sendError)
      end dispatchMessage
      """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"] + arguments
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
    try input.fileHandleForWriting.close()
    let timedOut = ProcessTimeout.waitUntilExit(process, timeout: 10)
    #expect(!timedOut)
    let diagnostic = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "\(diagnostic)")
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @Test
  func staleDirectChatUsesParticipantBeforeDispatch() throws {
    #expect(try runDirectChatScript() == "IMSG_RESULT\tok\tcompleted\t0|1|participant")
  }

  @Test
  func liveChatKeepsChatRouting() throws {
    #expect(try runDirectChatScript(lookupError: 0) == "IMSG_RESULT\tok\tcompleted\t0|1|chat")
  }

  @Test
  func staleDirectChatSendsTextAndAttachmentOnceEach() throws {
    #expect(
      try runDirectChatScript(attachment: true) == "IMSG_RESULT\tok\tcompleted\t0|2|participant")
    #expect(
      try runDirectChatScript(text: "", attachment: true)
        == "IMSG_RESULT\tok\tcompleted\t0|1|participant")
  }

  @Test
  func unverifiedChatDoesNotRecover() throws {
    #expect(try runDirectChatScript(account: "") == "IMSG_RESULT\tfailure\tnot_started\t-1728")
  }

  @Test
  func otherLookupErrorsDoNotRecover() throws {
    #expect(
      try runDirectChatScript(lookupError: -1743) == "IMSG_RESULT\tfailure\tnot_started\t-1743")
  }

  @Test
  func participantRecoveryPreservesAccountAndService() throws {
    #expect(
      try runDirectChatScript(accountError: -1728) == "IMSG_RESULT\tfailure\tnot_started\t-1728")
    #expect(
      try runDirectChatScript(smsAccount: true) == "IMSG_RESULT\tfailure\tnot_started\t-1728")
  }

  @Test(arguments: [0, -1728])
  func dispatchErrorsNeverRecover(lookupError: Int) throws {
    #expect(
      try runDirectChatScript(lookupError: lookupError, sendError: -1728)
        == "IMSG_RESULT\tfailure\tmay_have_completed\t-1728")
  }
#endif
