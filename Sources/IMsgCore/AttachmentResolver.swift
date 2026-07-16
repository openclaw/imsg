import Darwin
import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#endif

enum AttachmentResolver {
  private struct ConversionPlan {
    let targetExtension: String
    let mimeType: String
    let arguments: (_ input: String, _ output: String) -> [String]
  }

  static func resolve(_ path: String) -> (resolved: String, missing: Bool) {
    guard !path.isEmpty else { return ("", true) }
    let expanded = (path as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
    return (expanded, !(exists && !isDir.boolValue))
  }

  static func metadata(
    filename: String,
    transferName: String,
    uti: String,
    mimeType: String,
    totalBytes: Int64,
    isSticker: Bool,
    options: AttachmentQueryOptions = .default
  ) -> AttachmentMeta {
    let resolved = resolve(filename)
    let converted =
      options.convertUnsupported && !resolved.missing
      ? convertUnsupportedAttachment(path: resolved.resolved, uti: uti, mimeType: mimeType)
      : nil
    return AttachmentMeta(
      filename: filename,
      transferName: transferName,
      uti: uti,
      mimeType: mimeType,
      totalBytes: totalBytes,
      isSticker: isSticker,
      originalPath: resolved.resolved,
      convertedPath: converted?.path,
      convertedMimeType: converted?.mimeType,
      missing: resolved.missing
    )
  }

  static func displayName(filename: String, transferName: String) -> String {
    if !transferName.isEmpty { return transferName }
    if !filename.isEmpty { return filename }
    return "(unknown)"
  }

  static func convertedURL(for sourcePath: String, targetExtension: String) -> URL {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let values = try? sourceURL.resourceValues(forKeys: [
      .contentModificationDateKey, .fileSizeKey,
    ])
    let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    let size = values?.fileSize ?? 0
    let token = "\(sourceURL.path)|\(size)|\(modification)"
    let digest = cacheDigest(for: token)
    let base = sourceURL.deletingPathExtension().lastPathComponent
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    let prefix = base.isEmpty ? "attachment" : String(base.prefix(48))
    return conversionCacheDirectory()
      .appendingPathComponent("\(prefix)-\(digest.prefix(16)).\(targetExtension)")
  }

  private static func convertUnsupportedAttachment(
    path: String,
    uti: String,
    mimeType: String
  ) -> (path: String, mimeType: String)? {
    guard let plan = conversionPlan(path: path, uti: uti, mimeType: mimeType) else {
      return nil
    }
    let outputURL = convertedURL(for: path, targetExtension: plan.targetExtension)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      return (outputURL.path, plan.mimeType)
    }
    guard let ffmpegURL = executableURL(named: "ffmpeg") else {
      return nil
    }

    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      return nil
    }

    let temporaryURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).\(plan.targetExtension)")
    do {
      let status = try runConversionProcess(
        executableURL: ffmpegURL,
        arguments: plan.arguments(path, temporaryURL.path)
      )
      guard status == 0,
        FileManager.default.fileExists(atPath: temporaryURL.path)
      else {
        try? FileManager.default.removeItem(at: temporaryURL)
        return nil
      }
      try? FileManager.default.removeItem(at: outputURL)
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
      return (outputURL.path, plan.mimeType)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      return nil
    }
  }

  /// Default bound for external converters (ffmpeg). Hung converters must not
  /// block attachment metadata resolution indefinitely.
  static let conversionProcessTimeout: TimeInterval = 60

  static func runConversionProcess(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval = conversionProcessTimeout
  ) throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")

    try process.run()

    // Monotonic deadline so wall-clock jumps cannot stretch the bound.
    let clock = ContinuousClock()
    let bound = Duration.seconds(max(0.05, timeout))
    let deadline = clock.now + bound
    while process.isRunning {
      if clock.now >= deadline {
        terminateConversionProcess(process)
        process.waitUntilExit()
        return 128 + SIGTERM
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return process.terminationStatus
  }

  /// SIGTERM the process, then SIGKILL process and process-group after grace.
  private static func terminateConversionProcess(_ process: Process) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    let ownsProcessGroup = getpgid(pid) == pid
    process.terminate()
    if ownsProcessGroup {
      kill(-pid, SIGTERM)
    }

    let clock = ContinuousClock()
    let killDeadline = clock.now + .milliseconds(500)
    while process.isRunning, clock.now < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(pid, SIGKILL)
    }
    // The leader may exit on SIGTERM while a descendant ignores it. Escalate
    // the captured group independently of the leader's state.
    if ownsProcessGroup {
      kill(-pid, SIGKILL)
    }
  }

  private static func conversionPlan(
    path: String,
    uti: String,
    mimeType: String
  ) -> ConversionPlan? {
    let lowerPath = path.lowercased()
    let lowerUTI = uti.lowercased()
    let lowerMime = mimeType.lowercased()
    if lowerUTI == "com.apple.coreaudio-format"
      || lowerPath.hasSuffix(".caf")
      || lowerMime == "audio/x-caf"
    {
      return ConversionPlan(targetExtension: "m4a", mimeType: "audio/mp4") { input, output in
        ["-nostdin", "-y", "-i", input, "-c:a", "aac", "-b:a", "128k", output]
      }
    }
    if lowerUTI == "com.compuserve.gif"
      || lowerPath.hasSuffix(".gif")
      || lowerMime == "image/gif"
    {
      return ConversionPlan(targetExtension: "png", mimeType: "image/png") { input, output in
        ["-nostdin", "-y", "-i", input, "-vframes", "1", output]
      }
    }
    return nil
  }

  private static func conversionCacheDirectory() -> URL {
    if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
      return caches.appendingPathComponent("imsg/converted-attachments", isDirectory: true)
    }
    return FileManager.default.temporaryDirectory.appendingPathComponent(
      "imsg/converted-attachments",
      isDirectory: true
    )
  }

  private static func cacheDigest(for token: String) -> String {
    #if canImport(CryptoKit)
      return SHA256.hash(data: Data(token.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    #else
      // Linux Swift does not ship CryptoKit. This digest only names cache files;
      // it is not used as a security boundary, so stable FNV-1a is enough.
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in token.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      return String(format: "%016llx", hash)
    #endif
  }

  private static func executableURL(named name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let candidates =
      path.split(separator: ":").map(String.init)
      + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    for directory in candidates {
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
    }
    return nil
  }
}
