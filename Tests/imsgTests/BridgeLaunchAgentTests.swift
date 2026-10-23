import Commander
import Foundation
import Testing

@testable import imsg

@Test
func bridgeAgentDefaultPropertyList() throws {
  let agent = try BridgeLaunchAgent(
    executable: "bin/imsg", currentDirectory: "/opt/imsg", homeDirectory: "/Users/fixture")
  let expected: [String: Any] = [
    "Label": "org.openclaw.imsg.bridge",
    "ProgramArguments": ["/opt/imsg/bin/imsg", "launch"],
    "RunAtLoad": true,
    "StartInterval": 300,
    "ProcessType": "Background",
    "StandardOutPath": "/Users/fixture/Library/Logs/imsg/bridge-agent.log",
    "StandardErrorPath": "/Users/fixture/Library/Logs/imsg/bridge-agent.log",
  ]
  #expect(NSDictionary(dictionary: agent.propertyList).isEqual(to: expected))
  #expect(agent.plistPath == "/Users/fixture/Library/LaunchAgents/org.openclaw.imsg.bridge.plist")
}

@Test(arguments: [60, 600, 3600])
func bridgeAgentCustomIntervalAndDylib(interval: Int) throws {
  let agent = try BridgeLaunchAgent(
    executable: "/opt/imsg/current/imsg", currentDirectory: "/opt/imsg",
    homeDirectory: "/Users/fixture", interval: interval, dylib: "helpers/custom.dylib")
  #expect(agent.propertyList["StartInterval"] as? Int == interval)
  #expect(
    agent.propertyList["ProgramArguments"] as? [String]
      == ["/opt/imsg/current/imsg", "launch", "--dylib", "/opt/imsg/helpers/custom.dylib"])
}

@Test(arguments: [".build/release/helper.dylib", "/opt/imsg/lib/helper.dylib"], [false, true])
func bridgeAgentPreservesRelativeDiscoveryContext(automaticDylib: String, explicit: Bool) throws {
  let agent = try BridgeLaunchAgent(
    executable: "bin/imsg", currentDirectory: "/work/imsg", homeDirectory: "/Users/fixture",
    dylib: explicit ? "custom/helper.dylib" : nil, automaticDylib: automaticDylib)
  #expect(
    agent.propertyList["WorkingDirectory"] as? String
      == (!explicit && !automaticDylib.hasPrefix("/") ? "/work/imsg" : nil))
  #expect(
    agent.propertyList["ProgramArguments"] as? [String]
      == (["/work/imsg/bin/imsg", "launch"]
        + (explicit ? ["--dylib", "/work/imsg/custom/helper.dylib"] : [])))
}

@Test
func bridgeAgentPreservesRealExecutableSymlink() throws {
  let directory = try agentTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let release = directory.appendingPathComponent("releases/v1")
  try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
  try Data().write(to: release.appendingPathComponent("imsg"))
  try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("current"), withDestinationURL: release)
  for executable in ["current/imsg", directory.path + "/current/imsg"] {
    let agent = try BridgeLaunchAgent(
      executable: executable, currentDirectory: directory.path, homeDirectory: directory.path,
      dylib: "/opt/helpers/current/bridge.dylib")
    #expect(agent.program == directory.path + "/current/imsg")
    #expect(
      agent.propertyList["ProgramArguments"] as? [String]
        == [
          directory.path + "/current/imsg", "launch", "--dylib",
          "/opt/helpers/current/bridge.dylib",
        ])
  }
}

@Test
func bridgeAgentResolvesPATHWithoutResolvingSymlinks() throws {
  var checked: [String] = []
  let executable = try BridgeLaunchAgent.executablePath(
    invoked: "imsg", currentDirectory: "/work", searchPath: "/missing:/opt/imsg/current:/bin"
  ) { candidate in
    checked.append(candidate)
    return candidate == "/opt/imsg/current/imsg"
  }
  #expect(executable == "/opt/imsg/current/imsg")
  #expect(checked == ["/missing/imsg", "/opt/imsg/current/imsg"])
  for searchPath in ["", ":/bin", "bin:/bin"] {
    let expected = searchPath.hasPrefix("bin") ? "/work/bin/imsg" : "/work/imsg"
    #expect(
      try BridgeLaunchAgent.executablePath(
        invoked: "imsg", currentDirectory: "/work", searchPath: searchPath,
        isExecutable: { $0 == expected }) == expected)
  }
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try BridgeLaunchAgent.executablePath(
      invoked: "imsg", currentDirectory: "/work", searchPath: "/bin", isExecutable: { _ in false })
  }
  #expect(
    try BridgeLaunchAgent.executablePath(
      invoked: "current/imsg", currentDirectory: "/work", searchPath: "/bin",
      isExecutable: { _ in
        Issue.record("An explicit executable path must not be searched on PATH")
        return false
      }) == "/work/current/imsg")
}

@Test(arguments: [Int.min, -1, 0, 59])
func bridgeAgentRejectsShortInterval(interval: Int) {
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try BridgeLaunchAgent(
      executable: "/opt/imsg", currentDirectory: "/", homeDirectory: "/Users/fixture",
      interval: interval)
  }
}

@Test(
  arguments: [
    ["--install-agent", "--uninstall-agent"],
    ["--install-agent", "--kill-only"],
    ["--install-agent", "--force"],
    ["--uninstall-agent", "--kill-only"],
    ["--uninstall-agent", "--force"],
  ])
func bridgeAgentRejectsFlagConflictsBeforeAnyWork(arguments: [String]) async throws {
  let values = try CommandParser(signature: LaunchCommand.spec.signature).parse(
    arguments: arguments)
  await #expect(throws: BridgeLaunchAgent.Failure.self) {
    try await LaunchCommand.run(values: values, runtime: RuntimeOptions(parsedValues: values))
  }
}

@Test(arguments: ["59", "0", "-1", "1.5", "invalid", "9223372036854775808"])
func bridgeAgentRejectsInvalidCLIInterval(raw: String) throws {
  let values = try CommandParser(signature: LaunchCommand.spec.signature).parse(
    arguments: ["--install-agent", "--agent-interval", raw])
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try LaunchCommand.validateAgentOptions(values)
  }
}

@Test(arguments: [[], ["--uninstall-agent"], ["--force"], ["--kill-only"]])
func bridgeAgentIntervalRequiresInstallation(arguments: [String]) throws {
  let values = try CommandParser(signature: LaunchCommand.spec.signature).parse(
    arguments: arguments + ["--agent-interval", "600"])
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try LaunchCommand.validateAgentOptions(values)
  }
}

@Test
func bridgeAgentAcceptsDefaultAndCustomCLIInterval() throws {
  for (arguments, expected) in [
    (["--install-agent"], 300),
    (["--install-agent", "--agent-interval", "60"], 60),
    (["--install-agent", "--agent-interval", "600"], 600),
  ] {
    let values = try CommandParser(signature: LaunchCommand.spec.signature).parse(
      arguments: arguments)
    #expect(try LaunchCommand.validateAgentOptions(values) == expected)
  }
}

@Test
func bridgeAgentInstallationReplacesPlistBeforeLoading() throws {
  let directory = try agentTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  for interval in [300, 600] {
    let agent = try BridgeLaunchAgent(
      executable: "/opt/imsg/current/imsg", currentDirectory: "/",
      homeDirectory: directory.path, interval: interval)
    var calls: [[String]] = []
    try agent.install(userID: 501) { arguments in
      calls.append(arguments)
      let data = try Data(contentsOf: URL(fileURLWithPath: agent.plistPath))
      let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      #expect(NSDictionary(dictionary: plist).isEqual(to: agent.propertyList))
      let attributes = try FileManager.default.attributesOfItem(atPath: agent.plistPath)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
      #expect(FileManager.default.fileExists(atPath: directory.path + "/Library/Logs/imsg"))
      return arguments[0] == "bootout" ? 3 : 0
    }
    #expect(
      calls == [
        ["bootout", "gui/501/org.openclaw.imsg.bridge"],
        ["bootstrap", "gui/501", agent.plistPath],
      ])
    let files = try FileManager.default.contentsOfDirectory(
      atPath: directory.path + "/Library/LaunchAgents")
    #expect(files == ["org.openclaw.imsg.bridge.plist"])
  }
}

@Test(arguments: [0, 3, 113])
func bridgeAgentUninstallIsIdempotent(bootoutResult: Int32) throws {
  let directory = try agentTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let agent = try BridgeLaunchAgent(
    executable: "/opt/imsg", currentDirectory: "/", homeDirectory: directory.path)
  try agent.install(userID: 501) { _ in 0 }
  for _ in 0..<2 {
    var calls: [[String]] = []
    try agent.uninstall(userID: 501) { arguments in
      calls.append(arguments)
      return bootoutResult
    }
    #expect(calls == [["bootout", "gui/501/org.openclaw.imsg.bridge"]])
    #expect(!FileManager.default.fileExists(atPath: agent.plistPath))
  }
}

@Test(arguments: ["bootout", "bootstrap"])
func bridgeAgentReportsLaunchctlFailures(operation: String) throws {
  let directory = try agentTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let agent = try BridgeLaunchAgent(
    executable: "/opt/imsg", currentDirectory: "/", homeDirectory: directory.path)
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try agent.install(userID: 501) { $0[0] == operation ? 5 : 0 }
  }
  #expect(throws: BridgeLaunchAgent.Failure.self) {
    try agent.uninstall(userID: 501) { _ in 5 }
  }
  #expect(FileManager.default.fileExists(atPath: agent.plistPath))
}

@Test
func bridgeAgentLogTrimmingIsBoundedAndPreservesSmallLogsAndSymlinks() throws {
  let directory = try agentTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = directory.appendingPathComponent("agent.log")
  let small = Data("fixture diagnostic\n".utf8)
  try small.write(to: log)
  BridgeLaunchAgent.trimLog(at: log.path)
  #expect(try Data(contentsOf: log) == small)
  try Data(repeating: 65, count: BridgeLaunchAgent.maximumLogBytes + 1).write(to: log)
  let link = directory.appendingPathComponent("link.log")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
  BridgeLaunchAgent.trimLog(at: link.path)
  #expect(try Data(contentsOf: log).count == BridgeLaunchAgent.maximumLogBytes + 1)
  let handle = try FileHandle(forWritingTo: log)
  defer { try? handle.close() }
  BridgeLaunchAgent.trimLog(at: log.path)
  #expect(try Data(contentsOf: log).isEmpty)
  try handle.write(contentsOf: small)
  #expect(try Data(contentsOf: log) == small)
}

@Test(arguments: [false, true])
func bridgeAgentSuccessfulNoninteractiveLaunchIsQuiet(json: Bool) async throws {
  let values = ParsedValues(positional: [], options: [:], flags: json ? ["jsonOutput"] : [])
  let (output, _) = try await StdoutCapture.capture {
    try LaunchCommand.reportLaunchSuccess(
      dylib: "/fixture/helper.dylib", runtime: RuntimeOptions(parsedValues: values),
      interactive: false)
  }
  if json {
    let payload = try #require(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    #expect(payload["status"] == "launched")
    #expect(output.split(separator: "\n").count == 1)
  } else {
    #expect(output.isEmpty)
  }
}

@Test(arguments: ["loaded", "unloaded"])
func bridgeAgentJSONReportsExactFields(loadedState: String) async throws {
  let agent = try BridgeLaunchAgent(
    executable: "/opt/imsg/current/imsg", currentDirectory: "/work", homeDirectory: "/Users/fixture"
  )
  let values = ParsedValues(positional: [], options: [:], flags: ["jsonOutput"])
  let (output, _) = try await StdoutCapture.capture {
    try LaunchCommand.reportAgent(
      agent, status: loadedState, runtime: RuntimeOptions(parsedValues: values))
  }
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  let expected: [String: Any] = [
    "status": loadedState, "label": "org.openclaw.imsg.bridge",
    "plist": "/Users/fixture/Library/LaunchAgents/org.openclaw.imsg.bridge.plist",
    "program": "/opt/imsg/current/imsg", "interval": 300,
  ]
  #expect(NSDictionary(dictionary: payload).isEqual(to: expected))
  #expect(output.split(separator: "\n").count == 1)
}

private func agentTestDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-agent-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
