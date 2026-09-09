import Foundation
import Testing

@testable import IMsgCore

private let bridgeOwnershipHost = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent(".build/helper-tests/BridgeOwnershipHost")

@Test(
  .enabled(
    if: FileManager.default.isExecutableFile(atPath: bridgeOwnershipHost.path),
    "Run make test-helper to build the native host; make test does this automatically."
  ))
func bridgeOwnershipServesRequestsAcrossProcessTakeover() async throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  var processes: [Process] = []
  defer {
    for process in processes where process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: home)
  }
  func startHost() throws -> Process {
    let process = Process()
    process.executableURL = bridgeOwnershipHost
    process.arguments = [home.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    processes.append(process)
    return process
  }
  func contents(_ name: String) -> String {
    (try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)) ?? ""
  }
  func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Helper lifecycle timed out")
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  func stopHost(_ process: Process) async throws {
    try Data().write(to: home.appendingPathComponent("stop-\(process.processIdentifier)"))
    try await waitFor { !process.isRunning }
    #expect(process.terminationStatus == 0)
  }
  let client = IMsgBridgeClient(launcher: MessagesLauncher(containerPath: home.path))
  func ping() async throws {
    let response = try await client.invokeWithoutLaunching(action: .ping)
    #expect(response["pong"] as? Bool == true)
  }
  let owner = try startHost()
  let ownerPID = String(owner.processIdentifier)
  try await waitFor { contents(".imsg-bridge-ready") == ownerPID }
  try await ping()

  let standby = try startHost()
  let standbyPID = String(standby.processIdentifier)
  try await waitFor { contents(".imsg-bridge.log").contains("stand by pid=\(standbyPID)") }
  for _ in 0..<10 { try await ping() }
  #expect(contents(".imsg-bridge-ready") == ownerPID)
  let claimsBeforeExit = contents(".imsg-bridge.log").components(separatedBy: "\n")
    .filter { $0.contains("v2 claimed") }
  #expect(claimsBeforeExit.count == 11)
  #expect(claimsBeforeExit.allSatisfy { $0.contains("pid=\(ownerPID) ") })

  // Exiting a standby must not remove the live owner's readiness.
  try await stopHost(standby)
  #expect(contents(".imsg-bridge-ready") == ownerPID)
  try await ping()
  let replacement = try startHost()
  let replacementPID = String(replacement.processIdentifier)
  try await waitFor { contents(".imsg-bridge.log").contains("stand by pid=\(replacementPID)") }

  try FileManager.default.removeItem(at: home.appendingPathComponent(".imsg-bridge-ready"))
  try await waitFor { contents(".imsg-bridge-ready") == ownerPID }
  try await ping()

  // Kill without destructor cleanup: the kernel must release ownership.
  #expect(kill(owner.processIdentifier, SIGKILL) == 0)
  try await waitFor { !owner.isRunning }
  try await waitFor { contents(".imsg-bridge-ready") == replacementPID }
  for _ in 0..<10 { try await ping() }
  let allClaims = contents(".imsg-bridge.log").components(separatedBy: "\n")
    .filter { $0.contains("v2 claimed") }
  #expect(allClaims.count == 23)
  #expect(allClaims.suffix(10).allSatisfy { $0.contains("pid=\(replacementPID) ") })
  try await stopHost(replacement)
  #expect(!client.isReady())
  #expect(
    FileManager.default.fileExists(
      atPath: home.appendingPathComponent(".imsg-bridge-owner.lock").path))
}
