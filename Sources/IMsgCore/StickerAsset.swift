import Foundation

#if os(macOS)
  import CryptoKit
  import Darwin
  import ImageIO
#endif

public struct PreparedStickerAsset: Sendable, Equatable {
  public let stagedPath: String
  public let sha256: String
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let uti: String
  public let byteCount: Int
  public let accessibilityLabel: String

  public init(
    stagedPath: String,
    sha256: String,
    pixelWidth: Int,
    pixelHeight: Int,
    uti: String,
    byteCount: Int,
    accessibilityLabel: String
  ) {
    self.stagedPath = stagedPath
    self.sha256 = sha256
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.uti = uti
    self.byteCount = byteCount
    self.accessibilityLabel = accessibilityLabel
  }
}

public enum StickerAssetError: LocalizedError, CustomStringConvertible, Sendable, Equatable {
  case unsupportedPlatform
  case symlink(String)
  case notRegularFile(String)
  case invalidSize(Int)
  case invalidFormat(String)
  case invalidDimensions(width: Int, height: Int)
  case invalidFrameCount(Int)
  case excessiveDecodedPixels(Int)
  case changedWhileReading
  case couldNotStage(String)

  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .unsupportedPlatform:
      return "sticker preparation requires macOS"
    case .symlink(let path):
      return "sticker path traverses a symbolic link: \(path)"
    case .notRegularFile(let path):
      return "sticker must be a regular file: \(path)"
    case .invalidSize(let size):
      return "sticker must be 1...512000 bytes (received \(size))"
    case .invalidFormat(let uti):
      return "unsupported sticker image format: \(uti)"
    case .invalidDimensions(let width, let height):
      return "sticker dimensions must be positive and at most 618x618 (received \(width)x\(height))"
    case .invalidFrameCount(let count):
      return "sticker must contain 1...100 image frames (received \(count))"
    case .excessiveDecodedPixels(let count):
      return "sticker animation contains too many decoded pixels (received \(count))"
    case .changedWhileReading:
      return "sticker file changed while it was being read"
    case .couldNotStage(let detail):
      return "could not stage sticker: \(detail)"
    }
  }
}

public enum StickerAssetPreparer {
  public static let maximumByteCount = 500 * 1024
  public static let maximumDimension = 618
  public static let maximumFrameCount = 100
  public static let maximumDecodedPixels = 25_000_000

  public static func prepare(
    at path: String,
    destinationRoot: URL? = nil
  ) throws -> PreparedStickerAsset {
    #if os(macOS)
      let bytes = try readValidatedBytes(at: path)
      let image = try inspectImage(bytes)
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let root = destinationRoot ?? defaultDestinationRoot()
      let destination = try stageValidatedBytes(
        bytes,
        root: root,
        filename: "\(hash.prefix(16)).\(image.extensionName)"
      )
      return PreparedStickerAsset(
        stagedPath: destination.path,
        sha256: hash,
        pixelWidth: image.width,
        pixelHeight: image.height,
        uti: image.uti,
        byteCount: bytes.count,
        accessibilityLabel: "Sticker"
      )
    #else
      throw StickerAssetError.unsupportedPlatform
    #endif
  }

  package static func discard(
    _ asset: PreparedStickerAsset,
    destinationRoot: URL? = nil
  ) {
    #if os(macOS)
      let root = destinationRoot ?? defaultDestinationRoot()
      discardStagedFile(at: asset.stagedPath, trustedRoot: root.path)
    #endif
  }
}

#if os(macOS)
  extension StickerAssetPreparer {
    private struct ImageInfo {
      let width: Int
      let height: Int
      let uti: String
      let extensionName: String
    }

    private static func normalizedLexicalPath(_ path: String) -> String {
      var result = (path as NSString).expandingTildeInPath
      if !result.hasPrefix("/") {
        result = (FileManager.default.currentDirectoryPath as NSString)
          .appendingPathComponent(result)
      }
      result = (result as NSString).standardizingPath
      if result == "/tmp" || result.hasPrefix("/tmp/") {
        result = "/private/tmp" + result.dropFirst(4)
      } else if result == "/var" || result.hasPrefix("/var/") {
        result = "/private/var" + result.dropFirst(4)
      } else if result == "/etc" || result.hasPrefix("/etc/") {
        result = "/private/etc" + result.dropFirst(4)
      }
      return result
    }

    private static func securelyOpenDirectory(_ path: String) throws -> (fd: Int32, path: String) {
      let normalized = normalizedLexicalPath(path)
      let components = (normalized as NSString).pathComponents.filter { $0 != "/" }
      var directoryFD = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
      guard directoryFD >= 0 else { throw StickerAssetError.notRegularFile(normalized) }
      for component in components {
        let nextFD = Darwin.openat(
          directoryFD,
          component,
          O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        Darwin.close(directoryFD)
        guard nextFD >= 0 else {
          throw StickerAssetError.symlink(
            "\(normalized) (blocked component: \(component), errno: \(errno))")
        }
        directoryFD = nextFD
      }
      return (directoryFD, normalized)
    }

    private static func securelyOpenForReading(_ path: String) throws -> (fd: Int32, path: String) {
      let normalized = normalizedLexicalPath(path)
      let leaf = (normalized as NSString).lastPathComponent
      guard !leaf.isEmpty else { throw StickerAssetError.notRegularFile(normalized) }
      let parentPath = (normalized as NSString).deletingLastPathComponent
      let parent = try securelyOpenDirectory(parentPath)
      let directoryFD = parent.fd
      let fileFD = Darwin.openat(directoryFD, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      Darwin.close(directoryFD)
      guard fileFD >= 0 else { throw StickerAssetError.notRegularFile(normalized) }
      return (fileFD, normalized)
    }

    private static func discardStagedFile(at path: String, trustedRoot: String) {
      let normalized = normalizedLexicalPath(path)
      let normalizedRoot = normalizedLexicalPath(trustedRoot)
      guard normalized.hasPrefix(normalizedRoot + "/") else { return }
      let directoryPath = (normalized as NSString).deletingLastPathComponent
      let filename = (normalized as NSString).lastPathComponent
      guard !filename.isEmpty, let directory = try? securelyOpenDirectory(directoryPath) else {
        return
      }
      _ = Darwin.unlinkat(directory.fd, filename, 0)
      Darwin.close(directory.fd)

      let parentPath = (directoryPath as NSString).deletingLastPathComponent
      let directoryName = (directoryPath as NSString).lastPathComponent
      guard !directoryName.isEmpty, let parent = try? securelyOpenDirectory(parentPath) else {
        return
      }
      _ = Darwin.unlinkat(parent.fd, directoryName, AT_REMOVEDIR)
      Darwin.close(parent.fd)
    }

    private static func readValidatedBytes(at path: String) throws -> Data {
      let opened = try securelyOpenForReading(path)
      let descriptor = opened.fd
      defer { Darwin.close(descriptor) }

      var openedInfo = stat()
      guard fstat(descriptor, &openedInfo) == 0,
        (openedInfo.st_mode & S_IFMT) == S_IFREG
      else {
        throw StickerAssetError.notRegularFile(opened.path)
      }
      let initialSize = Int(openedInfo.st_size)
      guard initialSize > 0, initialSize <= maximumByteCount else {
        throw StickerAssetError.invalidSize(initialSize)
      }

      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      var result = Data()
      result.reserveCapacity(initialSize)
      while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        guard result.count + chunk.count <= maximumByteCount else {
          throw StickerAssetError.invalidSize(result.count + chunk.count)
        }
        result.append(chunk)
      }
      var finalInfo = stat()
      guard fstat(descriptor, &finalInfo) == 0,
        finalInfo.st_dev == openedInfo.st_dev,
        finalInfo.st_ino == openedInfo.st_ino,
        finalInfo.st_size == openedInfo.st_size,
        finalInfo.st_mtimespec.tv_sec == openedInfo.st_mtimespec.tv_sec,
        finalInfo.st_mtimespec.tv_nsec == openedInfo.st_mtimespec.tv_nsec,
        finalInfo.st_ctimespec.tv_sec == openedInfo.st_ctimespec.tv_sec,
        finalInfo.st_ctimespec.tv_nsec == openedInfo.st_ctimespec.tv_nsec,
        result.count == initialSize
      else {
        throw StickerAssetError.changedWhileReading
      }
      return result
    }

    private static func stageValidatedBytes(
      _ bytes: Data,
      root: URL,
      filename: String
    ) throws -> URL {
      let normalizedRoot = normalizedLexicalPath(root.path)
      guard !SecurePath.hasSymlinkComponent(normalizedRoot) else {
        throw StickerAssetError.symlink(normalizedRoot)
      }
      let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard !SecurePath.hasSymlinkComponent(normalizedRoot) else {
        throw StickerAssetError.symlink(normalizedRoot)
      }

      let rootFD = Darwin.open(
        normalizedRoot,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
      )
      guard rootFD >= 0 else {
        throw StickerAssetError.couldNotStage("could not open destination directory")
      }
      defer { Darwin.close(rootFD) }

      let directoryName = UUID().uuidString
      guard Darwin.mkdirat(rootFD, directoryName, 0o700) == 0 else {
        throw StickerAssetError.couldNotStage("could not create destination directory")
      }
      var keepDirectory = false
      defer {
        if !keepDirectory {
          _ = Darwin.unlinkat(rootFD, directoryName, AT_REMOVEDIR)
        }
      }
      let directoryFD = Darwin.openat(
        rootFD,
        directoryName,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
      )
      guard directoryFD >= 0 else {
        throw StickerAssetError.couldNotStage("could not open destination directory")
      }
      defer { Darwin.close(directoryFD) }

      let fileFD = Darwin.openat(
        directoryFD,
        filename,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
      guard fileFD >= 0 else {
        throw StickerAssetError.couldNotStage("could not create destination file")
      }
      var keepFile = false
      defer {
        Darwin.close(fileFD)
        if !keepFile { _ = Darwin.unlinkat(directoryFD, filename, 0) }
      }

      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(
            fileFD,
            buffer.baseAddress?.advanced(by: offset),
            buffer.count - offset
          )
          if written < 0 && errno == EINTR { continue }
          guard written > 0 else {
            throw StickerAssetError.couldNotStage("could not write destination file")
          }
          offset += written
        }
      }
      guard Darwin.fsync(fileFD) == 0 else {
        throw StickerAssetError.couldNotStage("could not sync destination file")
      }

      var descriptorInfo = stat()
      guard fstat(fileFD, &descriptorInfo) == 0 else {
        throw StickerAssetError.couldNotStage("could not inspect destination file")
      }
      let destination =
        rootURL
        .appendingPathComponent(directoryName, isDirectory: true)
        .appendingPathComponent(filename, isDirectory: false)
      var pathInfo = stat()
      guard lstat(destination.path, &pathInfo) == 0,
        pathInfo.st_dev == descriptorInfo.st_dev,
        pathInfo.st_ino == descriptorInfo.st_ino,
        (pathInfo.st_mode & S_IFMT) == S_IFREG
      else {
        throw StickerAssetError.couldNotStage("destination path changed during staging")
      }
      keepFile = true
      keepDirectory = true
      return destination
    }

    private static func inspectImage(_ data: Data) throws -> ImageInfo {
      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, options),
        let rawUTI = CGImageSourceGetType(source)
      else {
        throw StickerAssetError.invalidFormat("unknown")
      }
      let frameCount = CGImageSourceGetCount(source)
      guard frameCount > 0, frameCount <= maximumFrameCount else {
        throw StickerAssetError.invalidFrameCount(frameCount)
      }
      let uti = rawUTI as String
      let extensionName: String
      switch uti {
      case "public.png": extensionName = "png"
      case "com.compuserve.gif": extensionName = "gif"
      case "public.jpeg": extensionName = "jpg"
      default: throw StickerAssetError.invalidFormat(uti)
      }
      guard hasCompleteContainer(data, uti: uti) else {
        throw StickerAssetError.invalidFormat("\(uti) (incomplete data)")
      }
      var firstWidth = 0
      var firstHeight = 0
      var decodedPixels = 0
      for index in 0..<frameCount {
        guard
          let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options)
            as? [CFString: Any]
        else {
          throw StickerAssetError.invalidFormat(uti)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else {
          throw StickerAssetError.invalidDimensions(width: width, height: height)
        }
        if index == 0 {
          firstWidth = width
          firstHeight = height
        }
        decodedPixels += width * height
        guard decodedPixels <= maximumDecodedPixels else {
          throw StickerAssetError.excessiveDecodedPixels(decodedPixels)
        }
        guard CGImageSourceCreateImageAtIndex(source, index, options) != nil else {
          throw StickerAssetError.invalidFormat(uti)
        }
      }
      return ImageInfo(
        width: firstWidth,
        height: firstHeight,
        uti: uti,
        extensionName: extensionName
      )
    }

    private static func hasCompleteContainer(_ data: Data, uti: String) -> Bool {
      switch uti {
      case "public.png":
        return data.suffix(12).elementsEqual([
          0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
      case "com.compuserve.gif":
        return data.last == 0x3B
      case "public.jpeg":
        return data.suffix(2).elementsEqual([0xFF, 0xD9])
      default:
        return false
      }
    }

    private static func defaultDestinationRoot() -> URL {
      MessageSender.defaultAttachmentsSubdirectory()
        .appendingPathComponent("stickers", isDirectory: true)
    }

  }
#endif
