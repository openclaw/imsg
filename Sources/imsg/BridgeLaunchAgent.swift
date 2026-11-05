import Foundation
import IMsgCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct BridgeLaunchAgent {
  static let label = "org.openclaw.imsg.bridge"
  static let defaultInterval = 300
  static let minimumInterval = 60
  static let maximumLogBytes = 1_048_576

  let program: String
  let interval: Int
  let plistPath: String
  let logPath: String
  private let arguments: [String]
  private let workingDirectory: String?
  private let readyTimeout: String?

  init(
    executable: String, currentDirectory: String, homeDirectory: String,
    interval: Int = defaultInterval, dylib: String? = nil, automaticDylib: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard interval >= Self.minimumInterval else {
      throw Failure("--agent-interval must be at least \(Self.minimumInterval) seconds.")
    }
    program = Self.absolutePath(executable, currentDirectory: currentDirectory)
    self.interval = interval
    plistPath = homeDirectory + "/Library/LaunchAgents/\(Self.label).plist"
    logPath = Self.logPath(homeDirectory: homeDirectory)
    var arguments = [program, "launch"]
    if let dylib {
      arguments += ["--dylib", Self.absolutePath(dylib, currentDirectory: currentDirectory)]
    }
    self.arguments = arguments
    if dylib == nil, let automaticDylib, !automaticDylib.hasPrefix("/") {
      workingDirectory = currentDirectory
    } else {
      workingDirectory = nil
    }
    // Slow hosts set a longer readiness wait for `imsg launch`; keep it for the agent's runs.
    let timeout = environment[LaunchReadinessTimeout.environmentKey]?
      .trimmingCharacters(in: .whitespaces)
    if let timeout, let seconds = TimeInterval(timeout), seconds.isFinite, seconds > 0 {
      readyTimeout = timeout
    } else {
      readyTimeout = nil
    }
  }

  var propertyList: [String: Any] {
    var plist: [String: Any] = [
      "Label": Self.label,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "StartInterval": interval,
      "ProcessType": "Background",
      "StandardOutPath": logPath,
      "StandardErrorPath": logPath,
    ]
    if let workingDirectory { plist["WorkingDirectory"] = workingDirectory }
    if let readyTimeout {
      plist["EnvironmentVariables"] = [LaunchReadinessTimeout.environmentKey: readyTimeout]
    }
    return plist
  }

  func install(
    userID: UInt32,
    runLaunchctl: ([String]) throws -> Int32 = BridgeLaunchAgent.launchctl
  ) throws {
    let manager = FileManager.default
    let destination = URL(fileURLWithPath: plistPath)
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(Self.label).\(UUID().uuidString).plist")
    defer { try? manager.removeItem(at: temporary) }
    let data = try PropertyListSerialization.data(
      fromPropertyList: propertyList, format: .xml, options: 0)
    try data.write(to: temporary, options: .withoutOverwriting)
    try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
    guard rename(temporary.path, destination.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    try Self.bootout(userID: userID, runLaunchctl: runLaunchctl)
    let result = try runLaunchctl(["bootstrap", "gui/\(userID)", plistPath])
    guard result == 0 else {
      throw Failure("launchctl bootstrap failed (exit \(result)); plist saved at \(plistPath).")
    }
  }

  func uninstall(
    userID: UInt32,
    runLaunchctl: ([String]) throws -> Int32 = BridgeLaunchAgent.launchctl
  ) throws {
    try Self.bootout(userID: userID, runLaunchctl: runLaunchctl)
    do {
      try FileManager.default.removeItem(atPath: plistPath)
    } catch CocoaError.fileNoSuchFile {
      // Already uninstalled.
    }
  }

  static func logPath(homeDirectory: String) -> String {
    homeDirectory + "/Library/Logs/imsg/bridge-agent.log"
  }

  static func executablePath(
    invoked: String, currentDirectory: String, searchPath: String,
    isExecutable: (String) -> Bool
  ) throws -> String {
    if invoked.contains("/") {
      return absolutePath(invoked, currentDirectory: currentDirectory)
    }
    for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
      let prefix = directory.isEmpty ? currentDirectory : String(directory)
      let candidate = absolutePath(prefix + "/" + invoked, currentDirectory: currentDirectory)
      if isExecutable(candidate) { return candidate }
    }
    throw Failure("Unable to find invoked executable '\(invoked)' on PATH.")
  }

  static func trimLog(at path: String) {
    // Truncate in place: launchd keeps stdout/stderr open on this inode.
    // Never follow a final symlink or block opening a non-regular file.
    let descriptor = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size > maximumLogBytes
    else { return }
    _ = ftruncate(descriptor, 0)
  }

  private static func absolutePath(_ path: String, currentDirectory: String) -> String {
    // Do not resolve symlinks: a "current" release link must survive upgrades.
    path.hasPrefix("/") ? path : currentDirectory + "/" + path
  }

  private static func bootout(
    userID: UInt32, runLaunchctl: ([String]) throws -> Int32
  ) throws {
    let result = try runLaunchctl(["bootout", "gui/\(userID)/\(label)"])
    // launchctl reports ESRCH or its service-not-found code for an unloaded job.
    guard result == 0 || result == 3 || result == 113 else {
      throw Failure("launchctl bootout failed (exit \(result)).")
    }
  }

  private static func launchctl(_ arguments: [String]) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    guard !ProcessTimeout.waitUntilExit(task, timeout: 15) else {
      throw Failure("launchctl \(arguments[0]) timed out.")
    }
    return task.terminationStatus
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
      self.description = description
    }
  }
}
