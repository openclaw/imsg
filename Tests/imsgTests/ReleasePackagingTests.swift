import Foundation
import Testing

@Test
func releaseWorkflowPackagesUniversalBuildOutput() throws {
  let workflow = try readRepositoryFile(".github/workflows/release.yml")

  #expect(workflow.contains("OUTPUT_DIR=dist scripts/build-universal.sh"))
  #expect(workflow.contains("files: dist/imsg-macos.zip"))
  #expect(workflow.contains("imsg-bridge-helper.dylib"))
  #expect(!workflow.contains("swift build -c release --product imsg"))
  #expect(!workflow.contains("cp .build/release/imsg dist/imsg"))
}

@Test
func universalBuildScriptDefaultsToBothMacArchitectures() throws {
  let script = try readRepositoryFile("scripts/build-universal.sh")

  #expect(script.contains(#"ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}"#))
  #expect(script.contains(#"HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"$ARCHES_VALUE"}"#))
  #expect(script.contains("lipo -create"))
  #expect(script.contains("imsg-bridge-helper.dylib"))
  #expect(script.contains(#"codesign --force --sign -"#))
  #expect(script.contains(#"cp "${DIST_DIR}/${APP_NAME}" "$OUTPUT_DIR/$APP_NAME""#))
  #expect(script.contains(#"cp "${DIST_DIR}/${HELPER_NAME}" "$OUTPUT_DIR/$HELPER_NAME""#))
}

@Test
func executablePlistDeclaresContactsUsageDescription() throws {
  let plist = try readRepositoryFile("Sources/imsg/Resources/Info.plist")
  let generator = try readRepositoryFile("scripts/generate-version.sh")
  let key = "NSContactsUsageDescription"
  let description = "Resolve contact names for Messages conversations."

  #expect(plist.contains("<key>\(key)</key>"))
  #expect(plist.contains("<string>\(description)</string>"))
  #expect(generator.contains("<key>\(key)</key>"))
  #expect(generator.contains("<string>\(description)</string>"))
}

private func readRepositoryFile(_ path: String) throws -> String {
  let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(path)
  return try String(contentsOf: url, encoding: .utf8)
}
