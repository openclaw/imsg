import Darwin
import Foundation
import Testing

@testable import IMsgCore

@Test
func processTimeoutKillsHungProcess() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  // `exec` replaces the shell with sleep so the Process PID is the sleeper
  // itself (no orphan child after we kill the converter PID).
  let hung = dir.appendingPathComponent("sleeper")
  try """
  #!/bin/sh
  exec sleep 30
  """.write(to: hung, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)

  let process = Process()
  process.executableURL = hung
  process.arguments = []
  process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
  process.standardError = FileHandle(forWritingAtPath: "/dev/null")

  try process.run()
  let clock = ContinuousClock()
  let start = clock.now
  let timedOut = ProcessTimeout.waitUntilExit(process, timeout: 0.4)
  let elapsed = start.duration(to: clock.now)

  #expect(timedOut)
  #expect(!process.isRunning)
  #expect(elapsed < .seconds(5))
  #expect(elapsed >= .milliseconds(300))
}

@Test
func processTimeoutAllowsQuickExit() throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
  process.arguments = []
  process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
  process.standardError = FileHandle(forWritingAtPath: "/dev/null")

  try process.run()
  let timedOut = ProcessTimeout.waitUntilExit(process, timeout: 5)
  #expect(!timedOut)
  #expect(process.terminationStatus == 0)
}

@Test
func processTimeoutKillsDescendantsAfterLeaderExits() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let pidFile = dir.appendingPathComponent("pids")
  let hung = dir.appendingPathComponent("process-tree")
  try """
  #!/bin/sh
  trap 'exit 0' TERM
  sh -c 'trap "" TERM; exec sleep 30' >/dev/null 2>&1 &
  child=$!
  printf '%s %s\n' "$$" "$child" > "\(pidFile.path)"
  printf R
  wait "$child"
  """.write(to: hung, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)

  let readyPipe = Pipe()
  let process = Process()
  process.executableURL = hung
  process.standardOutput = readyPipe
  process.standardError = FileHandle(forWritingAtPath: "/dev/null")
  try process.run()
  readyPipe.fileHandleForWriting.closeFile()

  let ready = readyPipe.fileHandleForReading.readData(ofLength: 1)
  try #require(ready == Data("R".utf8))
  let processIDs = try String(contentsOf: pidFile, encoding: .utf8)
    .split(separator: " ")
    .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  try #require(processIDs.count == 2)

  let timedOut = ProcessTimeout.waitUntilExit(process, timeout: 0.5)

  #expect(timedOut)
  for processID in processIDs {
    #expect(waitForProcessExit(processID))
  }
}

@Test
func processTimeoutReapsHungOsascript() throws {
  // Same launch shape as MessageSender.runOsascript / ReactCommand.runAppleScript:
  // /usr/bin/osascript -l AppleScript - with source on stdin.
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  process.arguments = ["-l", "AppleScript", "-"]
  let stdinPipe = Pipe()
  process.standardInput = stdinPipe
  process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
  process.standardError = FileHandle(forWritingAtPath: "/dev/null")

  try process.run()
  if let data = "delay 30\n".data(using: .utf8) {
    stdinPipe.fileHandleForWriting.write(data)
  }
  stdinPipe.fileHandleForWriting.closeFile()

  let clock = ContinuousClock()
  let start = clock.now
  let timedOut = ProcessTimeout.waitUntilExit(process, timeout: 0.6)
  let elapsed = start.duration(to: clock.now)

  #expect(timedOut)
  #expect(!process.isRunning)
  #expect(elapsed < .seconds(5))
  #expect(elapsed >= .milliseconds(400))
}

@Test
func processTimeoutAllowsCsrutilStatus() throws {
  let task = Process()
  let output = Pipe()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
  task.arguments = ["status"]
  task.standardOutput = output
  task.standardError = output
  try task.run()
  let timedOut = ProcessTimeout.waitUntilExit(task, timeout: MessagesLauncher.helperProcessTimeout)
  #expect(!timedOut)
  #expect(!task.isRunning)
}

private func waitForProcessExit(_ processID: pid_t) -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(2)
  while clock.now < deadline {
    errno = 0
    let result = kill(processID, 0)
    let probeError = errno
    if result == -1, probeError == ESRCH {
      return true
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  return false
}
