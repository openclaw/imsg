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
func universalBuildScriptShipsArm64eHelperSlice() throws {
  let script = try readRepositoryFile("scripts/build-universal.sh")

  #expect(script.contains(#"ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}"#))
  // The injected helper must default to arm64e — macOS 26 Messages refuses to
  // load an arm64-only dylib, which silently kills the bridge.
  #expect(script.contains(#"HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"arm64e arm64 x86_64"}"#))
  #expect(script.contains("lipo -create"))
  #expect(script.contains("--scratch-path"))
  #expect(script.contains("--show-bin-path"))
  #expect(script.contains(#"for bundle in "${PRODUCT_DIRS[0]}"/*.bundle"#))
  #expect(!script.contains(#".build/${ARCH}-apple-macosx"#))
  #expect(script.contains("imsg-bridge-helper.dylib"))
  // release.yml ships via this script only, so it must guard every helper slice.
  #expect(
    script.contains(
      #"if ! lipo -archs "${DIST_DIR}/${HELPER_NAME}" | tr ' ' '\n' | grep -Fxq "$ARCH"; then"#))
  #expect(script.contains("Helper missing required architecture slice"))
  #expect(script.contains(#"codesign --force --sign -"#))
  #expect(script.contains(#"cp "${DIST_DIR}/${APP_NAME}" "$OUTPUT_DIR/$APP_NAME""#))
  #expect(script.contains(#"cp "${DIST_DIR}/${HELPER_NAME}" "$OUTPUT_DIR/$HELPER_NAME""#))
}

@Test
func signAndNotarizeScriptDefaultsHelperToArm64e() throws {
  let script = try readRepositoryFile("scripts/sign-and-notarize.sh")

  // The notarize path defaults the helper to arm64e as well, and its lipo guard
  // must validate the HELPER arch list — not the CLI ARCH_LIST, which omits
  // arm64e. Assert the loop and its lipo check as one contiguous block so this
  // can't pass by matching the separate clang-args HELPER_ARCH_LIST loop.
  #expect(script.contains(#"HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"arm64e arm64 x86_64"}"#))
  #expect(script.contains("--scratch-path"))
  #expect(script.contains("--show-bin-path"))
  #expect(script.contains(#"for bundle in "${PRODUCT_DIRS[0]}"/*.bundle"#))
  #expect(!script.contains(#".build/${ARCH}-apple-macosx"#))
  #expect(
    script.contains(
      """
      for ARCH in "${HELPER_ARCH_LIST[@]}"; do
        if ! lipo -archs "$DIST_DIR/$HELPER_NAME" | tr ' ' '\\n' | grep -Fxq "$ARCH"; then
          echo "Helper missing required architecture slice: $ARCH" >&2
      """))
}

@Test
func linuxReleaseStaticallyLinksSwiftRuntime() throws {
  let script = try readRepositoryFile("scripts/build-linux.sh")

  #expect(script.contains("--static-swift-stdlib"))
}

@Test
func bridgeHelperBuildsUseRelocatableInstallName() throws {
  let developmentBuild = try readRepositoryFile("Makefile")
  let universalBuild = try readRepositoryFile("scripts/build-universal.sh")
  let notarizedBuild = try readRepositoryFile("scripts/sign-and-notarize.sh")

  #expect(developmentBuild.contains("-install_name @rpath/imsg-bridge-helper.dylib"))
  for script in [universalBuild, notarizedBuild] {
    #expect(script.contains(#"-install_name "@rpath/${HELPER_NAME}""#))
  }
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
