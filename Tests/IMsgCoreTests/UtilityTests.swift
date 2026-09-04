import Foundation
import Testing

@testable import IMsgCore

@Test
func attachmentResolverResolvesPaths() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("test.txt")
  try "hi".data(using: .utf8)!.write(to: file)

  let existing = AttachmentResolver.resolve(file.path)
  #expect(existing.missing == false)
  #expect(existing.resolved.hasSuffix("test.txt"))

  let missing = AttachmentResolver.resolve(dir.appendingPathComponent("missing.txt").path)
  #expect(missing.missing == true)

  let directory = AttachmentResolver.resolve(dir.path)
  #expect(directory.missing == true)
}

@Test
func attachmentResolverDisplayNamePrefersTransfer() {
  #expect(
    AttachmentResolver.displayName(filename: "file.dat", transferName: "nice.dat") == "nice.dat")
  #expect(AttachmentResolver.displayName(filename: "file.dat", transferName: "") == "file.dat")
  #expect(AttachmentResolver.displayName(filename: "", transferName: "") == "(unknown)")
}

@Test
func attachmentResolverReportsCachedConvertedCAF() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let source = dir.appendingPathComponent("voice.caf")
  try Data("caf".utf8).write(to: source)
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "m4a")
  try FileManager.default.createDirectory(
    at: converted.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("m4a".utf8).write(to: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let meta = AttachmentResolver.metadata(
    filename: source.path,
    transferName: "voice.caf",
    uti: "com.apple.coreaudio-format",
    mimeType: "audio/x-caf",
    totalBytes: 3,
    isSticker: false,
    options: AttachmentQueryOptions(convertUnsupported: true)
  )

  #expect(meta.originalPath == source.path)
  #expect(meta.convertedPath == converted.path)
  #expect(meta.convertedMimeType == "audio/mp4")
  #expect(meta.mimeType == "audio/x-caf")
}

@Test
func attachmentResolverConversionDoesNotBlockOnConverterOutput() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let source = dir.appendingPathComponent("voice.caf")
  try Data("caf".utf8).write(to: source)
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "m4a")
  try? FileManager.default.removeItem(at: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let fakeFFmpeg = dir.appendingPathComponent("ffmpeg")
  try """
  #!/bin/sh
  last=""
  for arg in "$@"; do
    last="$arg"
  done
  i=0
  while [ "$i" -lt 2048 ]; do
    printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n' >&2
    i=$((i + 1))
  done
  printf converted > "$last"
  exit 0
  """.write(to: fakeFFmpeg, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpeg.path)

  let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  setenv("PATH", "\(dir.path):\(oldPath)", 1)
  defer { setenv("PATH", oldPath, 1) }

  let meta = AttachmentResolver.metadata(
    filename: source.path,
    transferName: "voice.caf",
    uti: "com.apple.coreaudio-format",
    mimeType: "audio/x-caf",
    totalBytes: 3,
    isSticker: false,
    options: AttachmentQueryOptions(convertUnsupported: true)
  )

  #expect(meta.convertedPath == converted.path)
  #expect(meta.convertedMimeType == "audio/mp4")
}

@Test
func attachmentResolverLeavesUnsupportedFilesUnconverted() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let source = dir.appendingPathComponent("file.txt")
  try Data("text".utf8).write(to: source)
  let meta = AttachmentResolver.metadata(
    filename: source.path,
    transferName: "file.txt",
    uti: "public.plain-text",
    mimeType: "text/plain",
    totalBytes: 4,
    isSticker: false,
    options: AttachmentQueryOptions(convertUnsupported: true)
  )

  #expect(meta.convertedPath == nil)
  #expect(meta.convertedMimeType == nil)
}

@Test
func securePathDetectsFinalSymlink() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let target = dir.appendingPathComponent("target.txt")
  let link = dir.appendingPathComponent("link.txt")
  try Data("hello".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

  #expect(SecurePath.hasSymlinkComponent(target.path) == false)
  #expect(SecurePath.hasSymlinkComponent(link.path) == true)
}

@Test
func securePathDetectsParentSymlink() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let realParent = dir.appendingPathComponent("real")
  let linkParent = dir.appendingPathComponent("linked")
  try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: realParent)

  let realChild = realParent.appendingPathComponent("child.txt")
  let linkedChild = linkParent.appendingPathComponent("child.txt")
  try Data("hello".utf8).write(to: realChild)

  #expect(SecurePath.hasSymlinkComponent(realChild.path) == false)
  #expect(SecurePath.hasSymlinkComponent(linkedChild.path) == true)
}

@Test
func securePathDoesNotNormalizeAwaySymlinkedDotDotComponent() throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let realDirectory = root.appendingPathComponent("real", isDirectory: true)
  let link = root.appendingPathComponent("link", isDirectory: true)
  try fileManager.createDirectory(at: realDirectory, withIntermediateDirectories: true)
  try fileManager.createSymbolicLink(at: link, withDestinationURL: realDirectory)
  defer { try? fileManager.removeItem(at: root) }

  #expect(SecurePath.hasSymlinkComponent(link.appendingPathComponent("../queue").path))
}

@Test
func securePathAllowsTrustedSystemAliasPrefixes() throws {
  #expect(SecurePath.absoluteLexicalPath("/var/example") == "/private/var/example")
  let privateTmp = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
  let dirName = "imsg-secure-path-\(UUID().uuidString)"
  let realDir = privateTmp.appendingPathComponent(dirName)
  try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: realDir) }

  let realFile = realDir.appendingPathComponent("target.txt")
  try Data("hello".utf8).write(to: realFile)

  let aliasFile = "/tmp/\(dirName)/target.txt"
  #expect(SecurePath.hasSymlinkComponent(aliasFile) == false)

  let link = realDir.appendingPathComponent("link.txt")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
  #expect(SecurePath.hasSymlinkComponent("/tmp/\(dirName)/link.txt") == true)
}

@Test
func iso8601ParserParsesFormats() {
  let fractional = "2024-01-02T03:04:05.678Z"
  let standard = "2024-01-02T03:04:05Z"
  #expect(ISO8601Parser.parse(fractional) != nil)
  #expect(ISO8601Parser.parse(standard) != nil)
  #expect(ISO8601Parser.parse("") == nil)
}

@Test
func iso8601ParserFormatsDates() {
  let date = Date(timeIntervalSince1970: 0)
  let formatted = ISO8601Parser.format(date)
  #expect(formatted.contains("T"))
  #expect(ISO8601Parser.parse(formatted) != nil)
}

@Test
func messageFilterHonorsParticipantsAndDates() throws {
  let now = Date(timeIntervalSince1970: 1000)
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "Alice",
    text: "hi",
    date: now,
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
  let filter = MessageFilter(
    participants: ["alice"],
    startDate: now.addingTimeInterval(-10),
    endDate: now.addingTimeInterval(10)
  )
  #expect(filter.allows(message) == true)
  let pastFilter = MessageFilter(startDate: now.addingTimeInterval(5))
  #expect(pastFilter.allows(message) == false)
}

@Test
func messageFilterRejectsInvalidISO() {
  do {
    _ = try MessageFilter.fromISO(participants: [], startISO: "bad-date", endISO: nil)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .invalidISODate(let value):
      #expect(value == "bad-date")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func phoneNumberNormalizerFormatsValidNumber() {
  let normalizer = PhoneNumberNormalizer()
  let normalized = normalizer.normalize("+1 650-253-0000", region: "US")
  #expect(normalized == "+16502530000")
}

@Test
func phoneNumberNormalizerReturnsInputOnFailure() {
  let normalizer = PhoneNumberNormalizer()
  let normalized = normalizer.normalize("not-a-number", region: "US")
  #expect(normalized == "not-a-number")
}

@Test
func messageSenderBuildsArguments() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, args in
    captured = args
  })
  try sender.send(
    MessageSendOptions(
      recipient: "+16502530000",
      text: "hi",
      attachmentPath: "",
      service: .auto,
      region: "US"
    )
  )
  #expect(captured.count == 10)
  #expect(captured[0] == "+16502530000")
  #expect(captured[2] == "imessage")
  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
  #expect(Array(captured[7...]) == ["", "", ""])
}

@Test
func messageSenderUsesChatIdentifier() throws {
  let fileManager = FileManager.default
  let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: tempDir) }
  let attachment = tempDir.appendingPathComponent("file.dat")
  try Data("hello".utf8).write(to: attachment)
  let attachmentsSubdirectory = tempDir.appendingPathComponent("staged")
  try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)

  var captured: [String] = []
  let sender = MessageSender(
    runner: { _, args in captured = args },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
  )
  try sender.send(
    MessageSendOptions(
      recipient: "",
      text: "hi",
      attachmentPath: attachment.path,
      service: .sms,
      region: "US",
      chatIdentifier: "iMessage;+;chat123",
      chatGUID: "ignored-guid"
    )
  )
  #expect(captured[5] == "ignored-guid")
  #expect(captured[6] == "1")
  #expect(captured[4] == "1")
}

@Test
func messageSenderStagesAttachmentsBeforeSend() throws {
  let fileManager = FileManager.default
  let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
    UUID().uuidString
  )
  try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
  let sourceDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: sourceDir) }
  let sourceFile = sourceDir.appendingPathComponent("sample.txt")
  let payload = Data("hi".utf8)
  try payload.write(to: sourceFile)

  var captured: [String] = []
  let sender = MessageSender(
    runner: { _, args in captured = args },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
  )

  try sender.send(
    MessageSendOptions(
      recipient: "+16502530000",
      text: "",
      attachmentPath: sourceFile.path,
      service: .imessage,
      region: "US"
    )
  )

  let stagedPath = captured[3]
  #expect(stagedPath != sourceFile.path)
  #expect(stagedPath.hasPrefix(attachmentsSubdirectory.path))
  #expect(fileManager.fileExists(atPath: stagedPath))
  let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
  #expect(stagedData == payload)
}

@Test
func messageSenderThrowsWhenAttachmentsSubdirectoryIsReadOnly() throws {
  let fileManager = FileManager.default
  let readOnlyRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
  try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyRoot.path)
  defer {
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyRoot.path)
    try? fileManager.removeItem(at: readOnlyRoot)
  }
  let sourceFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let payload = Data("payload".utf8)
  try payload.write(to: sourceFile)
  defer { try? fileManager.removeItem(at: sourceFile) }

  let sender = MessageSender(
    runner: { _, _ in },
    attachmentsSubdirectoryProvider: { readOnlyRoot }
  )

  do {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "",
        attachmentPath: sourceFile.path,
        service: .imessage,
        region: "US"
      )
    )
    #expect(Bool(false))
  } catch {
    #expect(Bool(true))
  }
}

@Test
func messageSenderThrowsWhenAttachmentMissing() {
  let fileManager = FileManager.default
  let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
    UUID().uuidString
  )
  try? fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
  let missingFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  var runnerCalled = false
  let sender = MessageSender(
    runner: { _, _ in runnerCalled = true },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
  )

  do {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "",
        attachmentPath: missingFile,
        service: .imessage,
        region: "US"
      )
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    #expect(error.errorDescription?.contains("Attachment not found") == true)
  } catch {
    #expect(Bool(false))
  }

  #expect(runnerCalled == false)
}

@Test
func messageSenderTreatsHandleIdentifierAsRecipient() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, args in
    captured = args
  })
  try sender.send(
    MessageSendOptions(
      recipient: "",
      text: "hi",
      attachmentPath: "",
      service: .auto,
      region: "US",
      chatIdentifier: "+16502530000",
      chatGUID: ""
    )
  )
  #expect(captured[0] == "+16502530000")
  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
}

@Test
func errorDescriptionsIncludeDetails() {
  let error = IMsgError.invalidService("weird")
  #expect(error.errorDescription?.contains("Invalid service: weird") == true)
  let chatError = IMsgError.invalidChatTarget("bad")
  #expect(chatError.errorDescription?.contains("Invalid chat target: bad") == true)
  let dateError = IMsgError.invalidISODate("2024-99-99")
  #expect(dateError.errorDescription?.contains("Invalid ISO8601 date") == true)
  let scriptError = IMsgError.appleScriptFailure("nope")
  #expect(scriptError.errorDescription?.contains("AppleScript failed: nope") == true)
  let underlying = NSError(domain: "Test", code: 1)
  let permission = IMsgError.permissionDenied(path: "/tmp/chat.db", underlying: underlying)
  let permissionDescription = permission.errorDescription ?? ""
  #expect(permissionDescription.contains("Permission Error") == true)
  #expect(permissionDescription.contains("/tmp/chat.db") == true)
  #expect(permissionDescription.contains("parent launcher") == true)
  #expect(permissionDescription.contains("built-in Terminal.app") == true)
  #expect(permissionDescription.contains("stale entries") == true)
}
