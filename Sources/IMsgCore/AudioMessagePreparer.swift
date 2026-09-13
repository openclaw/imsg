import Foundation

#if os(macOS)
  import AudioToolbox
#endif

/// Prepares native voice notes without changing the caller's original audio.
public enum AudioMessagePreparer {
  public static func prepare(at path: String) throws -> String {
    try prepare(at: path, destinationRoot: MessageSender.defaultAttachmentsSubdirectory())
  }

  static func prepare(
    at path: String,
    destinationRoot: URL,
    convert: (URL, URL) throws -> Void = convertAudio
  ) throws -> String {
    #if os(macOS)
      // Snapshot through the same symlink/regular-file checks as other attachments.
      let stagedPath = try MessageSender.stageAttachment(at: path, destinationRoot: destinationRoot)
      let staged = URL(fileURLWithPath: stagedPath)
      let directory = staged.deletingLastPathComponent()
      let output = directory.appendingPathComponent(UUID().uuidString + ".caf")
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try convert(staged, output)
        guard isVoiceAudio(output) else { throw PreparationError.invalidOutput }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try FileManager.default.removeItem(at: staged)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      // Messages may read this after bridge acknowledgment; retain it like other staged attachments.
      return output.path
    #else
      throw PreparationError.unsupportedPlatform
    #endif
  }

  static func convertAudio(_ input: URL, _ output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    // A native audio flag alone is insufficient: MP3/AAC can render as an unplayable 00:00 bubble.
    process.arguments = [
      "-f", "caff", "-d", "opus@24000", "-b", "32000", "-c", "1", input.path, output.path,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    guard !ProcessTimeout.waitUntilExit(process), process.terminationStatus == 0 else {
      throw PreparationError.conversionFailed
    }
  }

  #if os(macOS)
    private static func isVoiceAudio(_ url: URL) -> Bool {
      var file: AudioFileID?
      guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &file) == noErr,
        let file
      else { return false }
      defer { AudioFileClose(file) }
      var format = AudioStreamBasicDescription()
      var formatSize = UInt32(MemoryLayout.size(ofValue: format))
      var duration: Float64 = 0
      var durationSize = UInt32(MemoryLayout.size(ofValue: duration))
      return AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr
        && format.mFormatID == kAudioFormatOpus && format.mSampleRate == 24_000
        && format.mChannelsPerFrame == 1
        && AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &durationSize, &duration)
          == noErr
        && duration.isFinite && duration > 0
    }
  #endif

  enum PreparationError: LocalizedError {
    case unsupportedPlatform
    case conversionFailed
    case invalidOutput

    var errorDescription: String? {
      switch self {
      case .unsupportedPlatform:
        return "Audio message preparation requires macOS."
      case .conversionFailed:
        return
          "Could not convert audio to CAF/Opus with afconvert. Use a macOS-supported audio file."
      case .invalidOutput:
        return "Audio conversion did not produce a nonempty CAF/Opus voice message."
      }
    }
  }
}
