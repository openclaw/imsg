import Foundation
import IMsgCore
import Testing

private let buildScriptRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

private func buildFixture() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("imsg build \(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func runBuildTool(_ executable: String, _ arguments: [String], at root: URL) throws
  -> String
{
  let process = Process()
  let pipe = Pipe()
  let reader = TestPipeReader(handle: pipe.fileHandleForReading)
  reader.startAndWaitUntilReady()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = root
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  try pipe.fileHandleForWriting.close()
  let timedOut = ProcessTimeout.waitUntilExit(process)
  let result = reader.waitForResult()
  let output = String(decoding: result.data, as: UTF8.self)
  try #require(!timedOut && process.terminationStatus == 0, "\(executable): \(output)")
  try #require(result.errorNumber == nil)
  return output
}

@Test
func dependencyPatchesUseSelectedScratchDirectoryAndAreIdempotent() throws {
  let root = try buildFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let scratch = root.appendingPathComponent("custom scratch")
  let sqlite = scratch.appendingPathComponent("checkouts/SQLite.swift/Package.swift")
  let phone = scratch.appendingPathComponent(
    "checkouts/PhoneNumberKit/Sources/PhoneNumberKit/Bundle+Resources.swift")
  for file in [sqlite, phone] {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  try "exclude: [\n            \"Info.plist\"\n        ]".write(
    to: sqlite, atomically: true, encoding: .utf8)
  try "#if DEBUG && SWIFT_PACKAGE\nBundle.main.bundleURL,\n#endif\n".write(
    to: phone, atomically: true, encoding: .utf8)
  let script = buildScriptRoot.appendingPathComponent("scripts/patch-deps.sh").path
  _ = try runBuildTool("/bin/bash", [script, scratch.path], at: root)
  let patchedSQLite = try String(contentsOf: sqlite, encoding: .utf8)
  let patchedPhone = try String(contentsOf: phone, encoding: .utf8)
  #expect(patchedSQLite.contains("PrivacyInfo.xcprivacy"))
  #expect(!patchedPhone.contains("DEBUG &&"))
  #expect(
    patchedPhone.contains("Bundle.main.bundleURL.resolvingSymlinksInPath()"))
  _ = try runBuildTool("/bin/bash", [script, scratch.path], at: root)
  #expect(try String(contentsOf: sqlite, encoding: .utf8) == patchedSQLite)
  #expect(try String(contentsOf: phone, encoding: .utf8) == patchedPhone)
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build").path))
}

@Test
func releasePhoneResourceLocatorResolvesExecutableSymlinks() throws {
  let root = try buildFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let product = root.appendingPathComponent("product")
  let links = root.appendingPathComponent("links")
  let bundle = product.appendingPathComponent("PhoneNumberKit_PhoneNumberKit.bundle")
  for directory in [bundle, links] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  let upstreamSource = buildScriptRoot.appendingPathComponent(
    ".build/checkouts/PhoneNumberKit/Sources/PhoneNumberKit/Bundle+Resources.swift")
  let scratch = root.appendingPathComponent("scratch")
  let source = scratch.appendingPathComponent(
    "checkouts/PhoneNumberKit/Sources/PhoneNumberKit/Bundle+Resources.swift")
  try FileManager.default.createDirectory(
    at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: upstreamSource, to: source)
  _ = try runBuildTool(
    "/bin/bash",
    [buildScriptRoot.appendingPathComponent("scripts/patch-deps.sh").path, scratch.path],
    at: root)
  let shim = root.appendingPathComponent("LegacyAccessor.swift")
  try """
  import Foundation
  extension Bundle {
    static let module: Bundle = {
      let path = Bundle.main.bundleURL.appendingPathComponent("PhoneNumberKit_PhoneNumberKit.bundle")
      guard let bundle = Bundle(url: path) else { fatalError("legacy resource lookup failed") }
      return bundle
    }()
  }
  """.write(to: shim, atomically: true, encoding: .utf8)
  let main = root.appendingPathComponent("main.swift")
  try "import Foundation\nprint(Bundle.phoneNumberKit.bundleURL.resolvingSymlinksInPath().path)\n"
    .write(to: main, atomically: true, encoding: .utf8)
  let binary = product.appendingPathComponent("resource-probe")
  _ = try runBuildTool(
    "/usr/bin/xcrun",
    ["swiftc", "-D", "SWIFT_PACKAGE", source.path, shim.path, main.path, "-o", binary.path],
    at: root)
  let link = links.appendingPathComponent("resource-probe")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
  let output = try runBuildTool(link.path, [], at: root)
  #expect(
    output.trimmingCharacters(in: .whitespacesAndNewlines) == bundle.resolvingSymlinksInPath().path)
}

@Test
func developmentHelperTargetsDeclaredMacOSMinimum() throws {
  let root = try buildFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let sources = root.appendingPathComponent("Sources")
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  try FileManager.default.copyItem(
    at: buildScriptRoot.appendingPathComponent("Sources/IMsgHelper"),
    to: sources.appendingPathComponent("IMsgHelper"))
  _ = try runBuildTool(
    "/usr/bin/make",
    ["-f", buildScriptRoot.appendingPathComponent("Makefile").path, "build-dylib"], at: root)
  let binary = root.appendingPathComponent(".build/release/imsg-bridge-helper.dylib")
  let metadata = try runBuildTool(
    "/usr/bin/xcrun", ["vtool", "-show-build", binary.path], at: root)
  #expect(metadata.contains("minos 14.0"))
}
