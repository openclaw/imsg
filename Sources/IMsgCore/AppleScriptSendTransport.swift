import Foundation

enum AppleScriptSendTransport {
  /// Messages can legitimately take longer than the short helper default, but
  /// the child is always bounded.
  static let timeout: TimeInterval = IMsgBridgeProtocol.defaultSendResponseTimeout

  static func run(source: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"] + arguments
    let stdinPipe = Pipe()
    let captureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "imsg-osascript-\(UUID().uuidString)", isDirectory: true)
    let stdoutURL = captureDirectory.appendingPathComponent("stdout")
    let stderrURL = captureDirectory.appendingPathComponent("stderr")
    do {
      try FileManager.default.createDirectory(
        at: captureDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
      else {
        throw CocoaError(.fileWriteUnknown)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: stdoutURL.path)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: stderrURL.path)
    } catch {
      throw failure(.notStarted, "Unable to prepare bounded osascript output capture.")
    }
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    guard
      let stdoutHandle = FileHandle(forWritingAtPath: stdoutURL.path),
      let stderrHandle = FileHandle(forWritingAtPath: stderrURL.path)
    else {
      throw failure(.notStarted, "Unable to prepare bounded osascript output capture.")
    }
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }
    process.standardInput = stdinPipe
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    do {
      try process.run()
    } catch {
      throw failure(.notStarted, "osascript could not be launched.")
    }
    do {
      if let data = source.data(using: .utf8) {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
      }
      try stdinPipe.fileHandleForWriting.close()
    } catch {
      ProcessTimeout.terminate(process)
      process.waitUntilExit()
      throw failure(
        .mayHaveCompleted,
        "The osascript input channel failed after process launch."
      )
    }
    if ProcessTimeout.waitUntilExit(process, timeout: timeout) {
      throw failure(.mayHaveCompleted, "osascript timed out after \(Int(timeout)) seconds.")
    }
    try? stdoutHandle.synchronize()
    if process.terminationReason == .uncaughtSignal || process.terminationStatus != 0 {
      throw failure(
        .mayHaveCompleted,
        "osascript exited without an authoritative delivery phase."
      )
    }
    let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    switch interpret(output) {
    case .success:
      return
    case .failure(let disposition, let detail):
      throw failure(disposition, detail)
    }
  }

  static func interpret(_ output: String) -> AppleScriptTransportResult {
    let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\t", omittingEmptySubsequences: false)
      .map(String.init)
    guard fields.count == 4, fields[0] == "IMSG_RESULT" else {
      return .failure(
        .mayHaveCompleted,
        "osascript exited without the structured delivery result."
      )
    }
    if fields[1] == "ok", fields[2] == "completed" { return .success }
    let detail = "Messages automation failed with AppleScript error \(fields[3])."
    switch fields[2] {
    case DeliveryDisposition.notStarted.rawValue:
      return .failure(.notStarted, detail)
    case DeliveryDisposition.mayHaveCompleted.rawValue:
      return .failure(.mayHaveCompleted, detail)
    default:
      return .failure(.mayHaveCompleted, "osascript returned an unknown delivery phase.")
    }
  }

  private static func failure(
    _ disposition: DeliveryDisposition,
    _ detail: String
  ) -> DeliveryFailure {
    DeliveryFailure(
      disposition: disposition,
      transport: .appleScript,
      operation: "send",
      detail: detail
    )
  }
}

enum AppleScriptTransportResult: Equatable {
  case success
  case failure(DeliveryDisposition, String)
}
