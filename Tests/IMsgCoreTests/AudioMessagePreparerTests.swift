import AudioToolbox
import Darwin
import Foundation
import Testing

@testable import IMsgCore

private func audioTestDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func audioFixture(in directory: URL) throws -> URL {
  let fixture = try #require(
    Bundle.module.url(forResource: "tone.mp3", withExtension: "base64", subdirectory: "Fixtures"))
  let bytes = try #require(
    Data(base64Encoded: Data(contentsOf: fixture), options: .ignoreUnknownCharacters))
  let source = directory.appendingPathComponent("tone.mp3")
  try bytes.write(to: source)
  return source
}

@Test
func audioMessagePreparerConvertsMP3ToNativeVoiceAudio() throws {
  let directory = try audioTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = try audioFixture(in: directory)
  let originalBytes = try Data(contentsOf: original)
  let output = try AudioMessagePreparer.prepare(at: original.path, destinationRoot: directory)

  #expect(output.hasPrefix(directory.path + "/"))
  #expect(output.hasSuffix(".caf"))
  #expect(try Data(contentsOf: original) == originalBytes)
  let outputURL = URL(fileURLWithPath: output)
  #expect(try Data(contentsOf: outputURL).prefix(4) == Data("caff".utf8))
  let attributes = try FileManager.default.attributesOfItem(atPath: output)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let directoryAttributes = try FileManager.default.attributesOfItem(
    atPath: outputURL.deletingLastPathComponent().path)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  let stagedFiles = try FileManager.default.contentsOfDirectory(
    atPath: outputURL.deletingLastPathComponent().path)
  #expect(stagedFiles == [outputURL.lastPathComponent])

  var file: AudioFileID?
  #expect(AudioFileOpenURL(outputURL as CFURL, .readPermission, 0, &file) == noErr)
  let audio = try #require(file)
  defer { AudioFileClose(audio) }
  var format = AudioStreamBasicDescription()
  var size = UInt32(MemoryLayout.size(ofValue: format))
  #expect(AudioFileGetProperty(audio, kAudioFilePropertyDataFormat, &size, &format) == noErr)
  #expect(format.mFormatID == kAudioFormatOpus)
  #expect(format.mChannelsPerFrame == 1)
  #expect(format.mSampleRate == 24_000)
  var duration: Float64 = 0
  size = UInt32(MemoryLayout.size(ofValue: duration))
  #expect(
    AudioFileGetProperty(audio, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr)
  #expect(duration > 0.4 && duration < 0.7)

  // CAF inputs are supported too; extension alone must never bypass codec normalization.
  let second = try AudioMessagePreparer.prepare(at: output, destinationRoot: directory)
  #expect(second != output)
  #expect(FileManager.default.fileExists(atPath: output))
  #expect(try Data(contentsOf: URL(fileURLWithPath: second)).prefix(4) == Data("caff".utf8))
}

@Test
func audioMessagePreparerDetectsContentInsteadOfTrustingExtension() throws {
  let directory = try audioTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("already a voice.caf")
  let original = try audioFixture(in: directory)
  try FileManager.default.copyItem(at: original, to: source)
  let output = try AudioMessagePreparer.prepare(
    at: source.path, destinationRoot: directory.appendingPathComponent("staged"))
  #expect(try Data(contentsOf: URL(fileURLWithPath: output)).prefix(4) == Data("caff".utf8))
  #expect(try Data(contentsOf: source) == Data(contentsOf: original))
}

@Test(arguments: ["", "not audio"])
func audioMessagePreparerRejectsInvalidAudioAndRemovesStaging(contents: String) throws {
  let directory = try audioTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("invalid.mp3")
  let staging = directory.appendingPathComponent("staged")
  try Data(contents.utf8).write(to: source)
  #expect(throws: AudioMessagePreparer.PreparationError.self) {
    try AudioMessagePreparer.prepare(at: source.path, destinationRoot: staging)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
  #expect(try Data(contentsOf: source) == Data(contents.utf8))
}

@Test(arguments: [false, true])
func audioMessagePreparerRejectsPartialOrInvalidConverterOutput(converterThrows: Bool) throws {
  let directory = try audioTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = try audioFixture(in: directory)
  let staging = directory.appendingPathComponent("staged")
  #expect(throws: AudioMessagePreparer.PreparationError.self) {
    try AudioMessagePreparer.prepare(at: source.path, destinationRoot: staging) { input, output in
      #expect(input.path != source.path)
      #expect(try Data(contentsOf: input) == Data(contentsOf: source))
      try Data("caff".utf8).write(to: output)
      if converterThrows { throw AudioMessagePreparer.PreparationError.conversionFailed }
    }
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test
func audioMessagePreparerRejectsUnsafeSourcesBeforeConversion() throws {
  let directory = try audioTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let link = directory.appendingPathComponent("linked.mp3")
  try FileManager.default.createSymbolicLink(
    at: link, withDestinationURL: audioFixture(in: directory))
  let fifo = directory.appendingPathComponent("audio.fifo")
  #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
  var converted = false
  for path in [link.path, fifo.path, directory.path] {
    #expect(throws: IMsgError.self) {
      try AudioMessagePreparer.prepare(
        at: path, destinationRoot: directory.appendingPathComponent("staged")
      ) { _, _ in converted = true }
    }
  }
  #expect(!converted)
}
