import Foundation
import Testing

@testable import IMsgCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Test
func messageSenderCanonicalizesStagingBelowSymlinkedAttachmentsRoot() throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let realRoot = root.appendingPathComponent("real", isDirectory: true)
  let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
  let source = root.appendingPathComponent("source.txt")
  try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
  try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
  try Data("payload".utf8).write(to: source)
  try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
  defer { try? fileManager.removeItem(at: root) }

  var captured: [String] = []
  let sender = MessageSender(
    runner: { _, args in captured = args },
    attachmentsSubdirectoryProvider: { linkedRoot }
  )
  try sender.send(
    MessageSendOptions(
      recipient: "+16502530000",
      attachmentPath: source.path,
      service: .imessage
    ))

  let stagedPath = captured[3]
  #expect(stagedPath.hasPrefix(realRoot.path))
  #expect(!stagedPath.hasPrefix(linkedRoot.path))
  #expect(SecurePath.hasSymlinkComponent(stagedPath) == false)
  #expect(try Data(contentsOf: URL(fileURLWithPath: stagedPath)) == Data("payload".utf8))
  let stagedAttributes = try fileManager.attributesOfItem(atPath: stagedPath)
  #expect((stagedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test
func messageSenderRejectsCallerControlledAttachmentSymlinkBeforeStaging() throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let realRoot = root.appendingPathComponent("real", isDirectory: true)
  let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
  let finalLink = root.appendingPathComponent("linked.txt")
  let dotDotTraversal = linkedRoot.path + "/../source.txt"
  let source = realRoot.appendingPathComponent("source.txt")
  try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
  try Data("private payload".utf8).write(to: source)
  try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
  try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
  try fileManager.createSymbolicLink(at: finalLink, withDestinationURL: source)
  defer { try? fileManager.removeItem(at: root) }

  var didRun = false
  let sender = MessageSender(
    runner: { _, _ in didRun = true },
    attachmentsSubdirectoryProvider: { realRoot }
  )

  for attackPath in [
    linkedRoot.appendingPathComponent("source.txt").path,
    finalLink.path,
    dotDotTraversal,
  ] {
    #expect(throws: IMsgError.self) {
      try sender.send(
        MessageSendOptions(
          recipient: "+16502530000",
          attachmentPath: attackPath,
          service: .imessage
        ))
    }
  }
  #expect(didRun == false)
}

@Test
func messageSenderRejectsFIFOWithoutBlocking() throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fifo = root.appendingPathComponent("attachment.fifo")
  try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
  defer { try? fileManager.removeItem(at: root) }

  var didRun = false
  let sender = MessageSender(
    runner: { _, _ in didRun = true },
    attachmentsSubdirectoryProvider: { root.appendingPathComponent("staged") }
  )

  #expect(throws: IMsgError.self) {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        attachmentPath: fifo.path,
        service: .imessage
      ))
  }
  #expect(didRun == false)
}
