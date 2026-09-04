import Foundation

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
  public var directParticipantTarget: DirectParticipantTarget?

  public init(
    recipient: String,
    text: String = "",
    attachmentPath: String = "",
    service: MessageService = .auto,
    region: String = "US",
    chatIdentifier: String = "",
    chatGUID: String = "",
    allowSMSFallback: Bool = true,
    directParticipantTarget: DirectParticipantTarget? = nil
  ) {
    self.recipient = recipient
    self.text = text
    self.attachmentPath = attachmentPath
    self.service = service
    self.region = region
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
    self.allowSMSFallback = allowSMSFallback
    self.directParticipantTarget = directParticipantTarget
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
    _ = try sendResolvingRoute(options)
  }

  public func normalizedRecipient(_ recipient: String, region: String) -> String {
    normalizer.normalize(recipient, region: region.isEmpty ? "US" : region)
  }

  /// Returns the effective destination after normalization and any safe SMS fallback.
  public func sendResolvingRoute(_ options: MessageSendOptions) throws -> MessageSendOptions {
    #if !os(macOS)
      _ = options
      throw IMsgError.appleScriptFailure(
        "Sending requires Messages.app automation and is only supported on macOS.")
    #else
      var resolved = options
      let requestedService = resolved.service
      let chatTarget = resolveChatTarget(&resolved)
      let useChat = !chatTarget.isEmpty
      resolved.recipient = normalizedRecipient(resolved.recipient, region: resolved.region)
      if useChat == false {
        resolved.chatIdentifier = ""
        resolved.directParticipantTarget = nil
        if resolved.service == .auto { resolved.service = .imessage }
      }

      if resolved.attachmentPath.isEmpty == false {
        resolved.attachmentPath = try stageAttachment(at: resolved.attachmentPath)
      }

      let smsFallbackEligible =
        resolved.allowSMSFallback
        && requestedService == .auto
        && ((useChat && resolved.service == .auto) || (!useChat && resolved.service == .imessage))
        && !resolved.recipient.isEmpty
        && resolved.attachmentPath.isEmpty
        && !resolved.text.isEmpty
        && recipientIsPhoneNumber(resolved.recipient)

      return try sendViaAppleScript(
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
    let sourcePath = SecurePath.absoluteLexicalPath(path)
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let fileManager = FileManager.default
    let sourceHandle = try AttachmentSource.openFile(at: sourcePath)
    defer { try? sourceHandle.close() }

    try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let canonicalRoot = destinationRoot.resolvingSymlinksInPath()
    let attachmentDir = canonicalRoot.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try fileManager.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
    let destination = attachmentDir.appendingPathComponent(
      sourceURL.lastPathComponent,
      isDirectory: false
    )
    do {
      try AttachmentSource.copy(sourceHandle, to: destination)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
    return destination.path
  }

  static func defaultAttachmentsSubdirectory() -> URL {
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
  ) throws -> MessageSendOptions {
    let script = appleScript()
    let directTarget = resolved.directParticipantTarget.flatMap {
      $0.chatGUID == chatTarget ? $0 : nil
    }
    func arguments(forService service: MessageService, forceBuddy: Bool = false) -> [String] {
      [
        resolved.recipient,
        resolved.text,
        service.rawValue,
        resolved.attachmentPath,
        resolved.attachmentPath.isEmpty ? "0" : "1",
        chatTarget,
        useChat && !forceBuddy ? "1" : "0",
        directTarget?.accountID ?? "",
        directTarget?.recipient ?? "",
        directTarget?.service.rawValue ?? "",
      ]
    }

    do {
      try runner(script, arguments(forService: resolved.service))
      return resolved
    } catch let failure as DeliveryFailure {
      guard smsFallbackEligible, failure.retrySafe else { throw failure }
      try runner(script, arguments(forService: .sms, forceBuddy: true))
      var fallback = resolved
      fallback.service = .sms
      fallback.chatGUID = ""
      fallback.chatIdentifier = ""
      fallback.directParticipantTarget = nil
      return fallback
    }
  }

  private func appleScript() -> String {
    return """
      on run argv
          set dispatchPhase to "pre_dispatch"
          try
          set theRecipient to item 1 of argv
          set theMessage to item 2 of argv
          set theService to item 3 of argv
          set theFilePath to item 4 of argv
          set useAttachment to item 5 of argv
          set chatId to item 6 of argv
          set useChat to item 7 of argv
          set directAccountID to item 8 of argv
          set directRecipient to item 9 of argv
          set directService to item 10 of argv

          tell application "Messages"
              if useChat is "1" then
                  -- Resolve eagerly; only this lookup may recover before dispatch.
                  try
                      set targetChat to get chat id chatId
                  on error lookupMessage number lookupNumber
                      if lookupNumber is not -1728 or directAccountID is "" then
                          error number lookupNumber
                      end if
                      set targetAccount to get account id directAccountID
                      if directService is "imessage" then
                          if (service type of targetAccount) is not iMessage then error number -1728
                      else
                          if (service type of targetAccount) is not SMS then error number -1728
                      end if
                      set targetChat to get buddy directRecipient of targetAccount
                  end try
                  if theMessage is not "" then
                      set dispatchPhase to "dispatch_started"
                      send theMessage to targetChat
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      set dispatchPhase to "dispatch_started"
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
                      set dispatchPhase to "dispatch_started"
                      send theMessage to targetBuddy
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      set dispatchPhase to "dispatch_started"
                      send theFile to targetBuddy
                  end if
              end if
          end tell
          return "IMSG_RESULT" & tab & "ok" & tab & "completed" & tab & "0"
          on error errorMessage number errorNumber
          if dispatchPhase is "pre_dispatch" then
              return "IMSG_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber
          end if
          return "IMSG_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber
          end try
      end run
      """
  }

  private func resolveChatTarget(_ options: inout MessageSendOptions) -> String {
    let guid = options.chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = options.chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !guid.isEmpty {
      return guid
    }
    if !identifier.isEmpty && looksLikeHandle(identifier) {
      if options.recipient.isEmpty {
        options.recipient = identifier
      }
      return ""
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
      try AppleScriptSendTransport.run(source: source, arguments: arguments)
    #else
      _ = source
      _ = arguments
      throw IMsgError.appleScriptFailure(
        "Sending requires Messages.app automation and is only supported on macOS.")
    #endif
  }

}
