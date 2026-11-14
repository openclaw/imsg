import Foundation
import Testing

@testable import IMsgCore

#if os(macOS)
  @Test(arguments: [-1743, -1728, 0, 1728])
  func appleScriptErrorNumbersHaveASCIIEncoding(number: Int) throws {
    var script = ""
    try MessageSender(runner: { source, _ in script = source }).send(
      MessageSendOptions(recipient: "fixture@example.com", text: "fixture"))
    // Return before the Messages block: exercise only the production formatter.
    script = script.replacingOccurrences(
      of: "on run argv", with: "on run argv\nreturn my asciiNumber(\(number))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
    try input.fileHandleForWriting.close()
    #expect(!ProcessTimeout.waitUntilExit(process, timeout: 10))
    let diagnostic = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "\(diagnostic)")
    let result = output.fileHandleForReading.readDataToEndOfFile()
    #expect(result == Data("\(number)\n".utf8))
  }
#endif
