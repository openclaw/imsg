import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import IMsgCore

@Test
func stickerPreparationUsesContentIdentityAndTrustedStaging() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let sources = root.appendingPathComponent("sources", isDirectory: true)
  let staged = root.appendingPathComponent("staged", isDirectory: true)
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let firstBytes = try stickerPNG(width: 300, height: 240, red: 0xFF)
  let first = sources.appendingPathComponent("first-name.png")
  let renamed = sources.appendingPathComponent("renamed.bin")
  let different = sources.appendingPathComponent("different.png")
  try firstBytes.write(to: first)
  try firstBytes.write(to: renamed)
  try stickerPNG(width: 300, height: 240, red: 0x11).write(to: different)

  let preparedFirst = try StickerAssetPreparer.prepare(at: first.path, destinationRoot: staged)
  let preparedRenamed = try StickerAssetPreparer.prepare(at: renamed.path, destinationRoot: staged)
  let preparedDifferent = try StickerAssetPreparer.prepare(
    at: different.path, destinationRoot: staged)

  #expect(preparedFirst.sha256 == preparedRenamed.sha256)
  #expect(preparedFirst.sha256 != preparedDifferent.sha256)
  #expect(preparedFirst.pixelWidth == 300)
  #expect(preparedFirst.pixelHeight == 240)
  #expect(preparedFirst.uti == "public.png")
  #expect(preparedFirst.accessibilityLabel == "Sticker")
  #expect(preparedRenamed.accessibilityLabel == "Sticker")
  #expect(preparedFirst.stagedPath.hasSuffix(".png"))
  #expect(try Data(contentsOf: URL(fileURLWithPath: preparedFirst.stagedPath)) == firstBytes)
  let permissions =
    try FileManager.default.attributesOfItem(atPath: preparedFirst.stagedPath)[
      .posixPermissions
    ] as? NSNumber
  #expect(permissions?.intValue == 0o600)
  let firstDirectory = URL(fileURLWithPath: preparedFirst.stagedPath).deletingLastPathComponent()
  StickerAssetPreparer.discard(preparedFirst, destinationRoot: staged)
  #expect(!FileManager.default.fileExists(atPath: preparedFirst.stagedPath))
  #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
}

@Test
func stickerPreparationRejectsUnsafeOrInvalidInputs() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let staged = root.appendingPathComponent("staged", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let valid = root.appendingPathComponent("valid.png")
  try stickerPNG(width: 300, height: 300, red: 0xFF).write(to: valid)
  let linked = root.appendingPathComponent("linked.png")
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: valid)
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: linked.path, destinationRoot: staged)
  }

  let parentLink = root.appendingPathComponent("linked-parent")
  let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
  try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
  let linkedChild = parentLink.appendingPathComponent("child.png")
  try Data(contentsOf: valid).write(to: realParent.appendingPathComponent("child.png"))
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: linkedChild.path, destinationRoot: staged)
  }

  let corrupt = root.appendingPathComponent("corrupt.png")
  try Data("not an image".utf8).write(to: corrupt)
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: corrupt.path, destinationRoot: staged)
  }

  for (name, data) in [
    ("truncated.png", try stickerImage(width: 64, height: 64, uti: "public.png")),
    ("truncated.gif", try stickerImage(width: 64, height: 64, uti: "com.compuserve.gif")),
    ("truncated.jpg", try stickerImage(width: 64, height: 64, uti: "public.jpeg")),
  ] {
    let truncated = root.appendingPathComponent(name)
    try data.dropLast().write(to: truncated)
    #expect(throws: StickerAssetError.self) {
      try StickerAssetPreparer.prepare(at: truncated.path, destinationRoot: staged)
    }
  }

  let oversizedFile = root.appendingPathComponent("oversized.png")
  try Data(repeating: 0, count: StickerAssetPreparer.maximumByteCount + 1)
    .write(to: oversizedFile)
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: oversizedFile.path, destinationRoot: staged)
  }

  let oversizedDimensions = root.appendingPathComponent("too-wide.png")
  try stickerPNG(width: 619, height: 1, red: 0xFF).write(to: oversizedDimensions)
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: oversizedDimensions.path, destinationRoot: staged)
  }
  #expect(throws: StickerAssetError.self) {
    try StickerAssetPreparer.prepare(at: root.path, destinationRoot: staged)
  }
}

@Test
func stickerPreparationAcceptsDocumentedImageFormats() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let staged = root.appendingPathComponent("staged", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  for (uti, extensionName, frameCount) in [
    ("public.png", "png", 2),
    ("com.compuserve.gif", "gif", 2),
    ("public.jpeg", "jpg", 1),
  ] {
    let source = root.appendingPathComponent("source.\(extensionName)")
    try stickerImage(width: 64, height: 48, uti: uti, frameCount: frameCount)
      .write(to: source)
    let prepared = try StickerAssetPreparer.prepare(at: source.path, destinationRoot: staged)
    #expect(prepared.uti == uti)
    #expect(prepared.pixelWidth == 64)
    #expect(prepared.pixelHeight == 48)
  }
}

private func stickerPNG(width: Int, height: Int, red: UInt8) throws -> Data {
  try stickerImage(width: width, height: height, uti: "public.png", red: red)
}

private func stickerImage(
  width: Int,
  height: Int,
  uti: String,
  frameCount: Int = 1,
  red: UInt8 = 0xFF
) throws -> Data {
  let images = try (0..<frameCount).map { index in
    try stickerCGImage(width: width, height: height, red: red &- UInt8(index % 32))
  }
  let output = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      output,
      uti as CFString,
      frameCount,
      nil
    )
  else {
    throw StickerAssetError.invalidFormat("test-destination")
  }
  for image in images {
    CGImageDestinationAddImage(destination, image, nil)
  }
  guard CGImageDestinationFinalize(destination) else {
    throw StickerAssetError.invalidFormat("test-encode")
  }
  return output as Data
}

private func stickerCGImage(width: Int, height: Int, red: UInt8) throws -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw StickerAssetError.invalidFormat("test-context")
  }
  context.setFillColor(
    red: CGFloat(red) / 255,
    green: 0.25,
    blue: 0.5,
    alpha: 1
  )
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage() else {
    throw StickerAssetError.invalidFormat("test-image")
  }
  return image
}
