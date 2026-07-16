import Darwin
import Foundation
import Testing

@testable import IMsgCore

@Test
func attachmentResolverConversionTimesOutOnHungConverter() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  // `exec` replaces the shell with sleep so the Process PID is the sleeper
  // itself (no orphan child after we kill the converter PID).
  let hung = dir.appendingPathComponent("ffmpeg")
  try """
  #!/bin/sh
  exec sleep 30
  """.write(to: hung, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)

  let clock = ContinuousClock()
  let start = clock.now
  let exitStatus = try AttachmentResolver.runConversionProcess(
    executableURL: hung,
    arguments: ["-i", "in", "out"],
    timeout: 0.4
  )
  let elapsed = start.duration(to: clock.now)

  #expect(exitStatus == 128 + SIGTERM)
  #expect(elapsed < .seconds(5))
  #expect(elapsed >= .milliseconds(300))
}

@Test
func attachmentResolverConversionKillsDescendantsAfterLeaderExits() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  let pidFile = dir.appendingPathComponent("pids")
  let hung = dir.appendingPathComponent("ffmpeg")
  try """
  #!/bin/sh
  trap 'exit 0' TERM
  sh -c 'trap "" TERM; exec sleep 30' &
  child=$!
  printf '%s %s\n' "$$" "$child" > "\(pidFile.path)"
  wait "$child"
  """.write(to: hung, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)

  let exitStatus = try AttachmentResolver.runConversionProcess(
    executableURL: hung,
    arguments: [],
    timeout: 0.5
  )
  let processIDs = try String(contentsOf: pidFile, encoding: .utf8)
    .split(separator: " ")
    .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

  #expect(exitStatus == 128 + SIGTERM)
  #expect(processIDs.count == 2)
  for processID in processIDs {
    #expect(waitForProcessExit(processID))
  }
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
