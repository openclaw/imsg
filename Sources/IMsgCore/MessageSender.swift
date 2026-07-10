import Foundation

#if os(macOS)
  import Carbon
#endif

public enum MessageService: String, Sendable, CaseIterable {
  case auto
  case imessage
  case sms
}

public struct MessageSendOptions: Sendable {
  public var recipient: String
  public var text: String
  public var attachmentPath: String
  public var service: MessageService
  public var region: String
  public var chatIdentifier: String
  public var chatGUID: String
  public var allowSMSFallback: Bool

  public init(
    recipient: String,
    text: String = "",
    attachmentPath: String = "",
    service: MessageService = .auto,
    region: String = "US",
    chatIdentifier: String = "",
    chatGUID: String = "",
    allowSMSFallback: Bool = true
  ) {
    self.recipient = recipient
    self.text = text
    self.attachmentPath = attachmentPath
    self.service = service
    self.region = region
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
    self.allowSMSFallback = allowSMSFallback
  }
}

public struct MessageSender {
  private let normalizer: PhoneNumberNormalizer
  private let runner: (String, [String]) throws -> Void
  private let attachmentsSubdirectoryProvider: () -> URL

  public init() {
    self.normalizer = PhoneNumberNormalizer()
    self.runner = MessageSender.runAppleScript
    self.attachmentsSubdirectoryProvider = MessageSender.defaultAttachmentsSubdirectory
  }

  init(runner: @escaping (String, [String]) throws -> Void) {
    self.normalizer = PhoneNumberNormalizer()
    self.runner = runner
    self.attachmentsSubdirectoryProvider = MessageSender.defaultAttachmentsSubdirectory
  }

  init(
    runner: @escaping (String, [String]) throws -> Void,
    attachmentsSubdirectoryProvider: @escaping () -> URL
  ) {
    self.normalizer = PhoneNumberNormalizer()
    self.runner = runner
    self.attachmentsSubdirectoryProvider = attachmentsSubdirectoryProvider
  }

  public func send(_ options: MessageSendOptions) throws {
    #if !os(macOS)
      _ = options
      throw IMsgError.appleScriptFailure(
        "Sending requires Messages.app automation and is only supported on macOS.")
    #else
      var resolved = options
      let requestedService = resolved.service
      let chatTarget = resolveChatTarget(&resolved)
      let useChat = !chatTarget.isEmpty
      if useChat == false {
        if resolved.region.isEmpty { resolved.region = "US" }
        resolved.recipient = normalizer.normalize(resolved.recipient, region: resolved.region)
        if resolved.service == .auto { resolved.service = .imessage }
      }

      if resolved.attachmentPath.isEmpty == false {
        resolved.attachmentPath = try stageAttachment(at: resolved.attachmentPath)
      }

      let smsFallbackEligible =
        resolved.allowSMSFallback
        && requestedService == .auto
        && useChat == false
        && resolved.service == .imessage
        && resolved.attachmentPath.isEmpty
        && !resolved.text.isEmpty
        && recipientIsPhoneNumber(resolved.recipient)

      try sendViaAppleScript(
        resolved,
        chatTarget: chatTarget,
        useChat: useChat,
        smsFallbackEligible: smsFallbackEligible
      )
    #endif
  }

  private func recipientIsPhoneNumber(_ recipient: String) -> Bool {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.contains("@") { return false }
    return trimmed.contains(where: \.isNumber)
  }

  public static func stageAttachmentForMessagesApp(at path: String) throws -> String {
    try stageAttachment(at: path, destinationRoot: defaultAttachmentsSubdirectory())
  }

  private func stageAttachment(at path: String) throws -> String {
    try Self.stageAttachment(at: path, destinationRoot: attachmentsSubdirectoryProvider())
  }

  private static func stageAttachment(at path: String, destinationRoot: URL) throws -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    let sourceURL = URL(fileURLWithPath: expandedPath)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw IMsgError.appleScriptFailure("Attachment not found at \(sourceURL.path)")
    }

    try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let attachmentDir = destinationRoot.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try fileManager.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
    let destination = attachmentDir.appendingPathComponent(
      sourceURL.lastPathComponent,
      isDirectory: false
    )
    try fileManager.copyItem(at: sourceURL, to: destination)
    return destination.path
  }

  private static func defaultAttachmentsSubdirectory() -> URL {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let messagesRoot = home.appendingPathComponent(
      "Library/Messages/Attachments",
      isDirectory: true
    )
    return messagesRoot.appendingPathComponent("imsg", isDirectory: true)
  }

  private func sendViaAppleScript(
    _ resolved: MessageSendOptions,
    chatTarget: String,
    useChat: Bool,
    smsFallbackEligible: Bool
  ) throws {
    let script = appleScript()
    func arguments(forService service: MessageService) -> [String] {
      [
        resolved.recipient,
        resolved.text,
        service.rawValue,
        resolved.attachmentPath,
        resolved.attachmentPath.isEmpty ? "0" : "1",
        chatTarget,
        useChat ? "1" : "0",
      ]
    }

    do {
      try runner(script, arguments(forService: resolved.service))
    } catch {
      guard smsFallbackEligible else { throw error }
      do {
        try runner(script, arguments(forService: .sms))
      } catch let smsError {
        throw IMsgError.appleScriptFailure(
          "iMessage send failed (\(error.localizedDescription)); "
            + "SMS fallback also failed (\(smsError.localizedDescription))"
        )
      }
    }
  }

  private func appleScript() -> String {
    return """
      on run argv
          set theRecipient to item 1 of argv
          set theMessage to item 2 of argv
          set theService to item 3 of argv
          set theFilePath to item 4 of argv
          set useAttachment to item 5 of argv
          set chatId to item 6 of argv
          set useChat to item 7 of argv

          tell application "Messages"
              if useChat is "1" then
                  set targetChat to chat id chatId
                  if theMessage is not "" then
                      send theMessage to targetChat
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      send theFile to targetChat
                  end if
              else
                  if theService is "sms" then
                      set targetService to first service whose service type is SMS
                  else
                      set targetService to first service whose service type is iMessage
                  end if

                  set targetBuddy to buddy theRecipient of targetService
                  if theMessage is not "" then
                      send theMessage to targetBuddy
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      send theFile to targetBuddy
                  end if
              end if
          end tell
      end run
      """
  }

  private func resolveChatTarget(_ options: inout MessageSendOptions) -> String {
    let guid = options.chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = options.chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !identifier.isEmpty && looksLikeHandle(identifier) {
      if options.recipient.isEmpty {
        options.recipient = identifier
      }
      return ""
    }
    if !guid.isEmpty {
      return guid
    }
    if identifier.isEmpty {
      return ""
    }
    return identifier
  }

  private func looksLikeHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("imessage:") || lower.hasPrefix("sms:") || lower.hasPrefix("auto:") {
      return true
    }
    if trimmed.contains("@") { return true }
    let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
    return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
  }

  private static func runAppleScript(source: String, arguments: [String]) throws {
    #if os(macOS)
      guard let script = NSAppleScript(source: source) else {
        throw IMsgError.appleScriptFailure("Unable to compile AppleScript")
      }
      var errorInfo: NSDictionary?
      let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kASAppleScriptSuite),
        eventID: AEEventID(kASSubroutineEvent),
        targetDescriptor: nil,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
      )
      event.setParam(
        NSAppleEventDescriptor(string: "run"), forKeyword: AEKeyword(keyASSubroutineName))
      let list = NSAppleEventDescriptor.list()
      for (index, value) in arguments.enumerated() {
        list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
      }
      event.setParam(list, forKeyword: keyDirectObject)
      script.executeAppleEvent(event, error: &errorInfo)
      if let errorInfo {
        if shouldFallbackToOsascript(errorInfo: errorInfo) {
          try runOsascript(source: source, arguments: arguments)
          return
        }
        let message =
          (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
        throw IMsgError.appleScriptFailure(message)
      }
    #else
      _ = source
      _ = arguments
      throw IMsgError.appleScriptFailure(
        "Sending requires Messages.app automation and is only supported on macOS.")
    #endif
  }

  private static func shouldFallbackToOsascript(errorInfo: NSDictionary) -> Bool {
    #if os(macOS)
      if let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
        return true
      }
      if errorInfo[NSAppleScript.errorMessage] == nil {
        return true
      }
      if let message = errorInfo[NSAppleScript.errorMessage] as? String {
        let lower = message.lowercased()
        return lower.contains("not authorized") || lower.contains("not authorised")
      }
      return false
    #else
      _ = errorInfo
      return false
    #endif
  }

  private static func runOsascript(source: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"] + arguments
    let stdinPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardError = stderrPipe
    try process.run()
    if let data = source.data(using: .utf8) {
      stdinPipe.fileHandleForWriting.write(data)
    }
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "Unknown osascript error"
      throw IMsgError.appleScriptFailure(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}
