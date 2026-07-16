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
