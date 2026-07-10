import Foundation
import IMsgCore

#if os(macOS)
  import CryptoKit
  import ImageIO
  import UniformTypeIdentifiers
#endif

typealias RichLinkPrepare = (String) async throws -> PreparedRichLinkPreview

struct PreparedRichLinkPreview: Sendable, Equatable {
  struct Image: Sendable, Equatable {
    let filePath: String
    let mimeType: String
    let contentHash: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var bridgePayload: [String: Any] {
      [
        "filePath": filePath,
        "mimeType": mimeType,
        "contentHash": contentHash,
        "byteCount": byteCount,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
      ]
    }
  }

  let originalURL: String
  let resolvedURL: String
  let title: String
  let image: Image?

  var bridgePayload: [String: Any] {
    var payload: [String: Any] = [
      "version": 1,
      "originalURL": originalURL,
      "resolvedURL": resolvedURL,
      "title": title,
    ]
    if let image {
      payload["image"] = image.bridgePayload
    }
    return payload
  }

  func removeStagedImage() {
    guard let image else { return }
    let path = URL(fileURLWithPath: image.filePath).standardizedFileURL
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/Attachments/imsg", isDirectory: true)
      .standardizedFileURL
    guard path.path.hasPrefix(root.path + "/") else { return }
    try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
  }
}

struct RichLinkFetchedMetadata: Sendable {
  let resolvedURL: String?
  let title: String?
  let imageData: Data?

  init(
    resolvedURL: String? = nil,
    title: String? = nil,
    imageData: Data? = nil
  ) {
    self.resolvedURL = resolvedURL
    self.title = title
    self.imageData = imageData
  }
}

enum RichLinkPreparationError: Error, LocalizedError, Equatable, Sendable {
  case invalidURL(String)
  case unsupportedBridge
  case unsupportedPlatform

  var errorDescription: String? {
    switch self {
    case .invalidURL(let reason): return "Invalid rich-link URL: \(reason)"
    case .unsupportedBridge:
      return
        "Running bridge does not support rich links; restart Messages with the current imsg bridge"
    case .unsupportedPlatform: return "Rich-link preparation requires macOS"
    }
  }
}

func bridgeSupportsRichLinks(_ status: [String: Any]) -> Bool {
  guard let selectors = status["selectors"] as? [String: Any] else { return false }
  return selectors["urlPreviewMessage"] as? Bool == true
    && selectors["sendRichLinkAction"] as? Bool == true
}

enum RichLinkPreparer {
  typealias MetadataLoader = @Sendable (URL) async throws -> RichLinkFetchedMetadata?
  typealias ImageStager = @Sendable (Data) throws -> String

  private static let maximumURLBytes = 8 * 1024
  private static let maximumTitleBytes = 1024
  static let maximumImageBytes = 2 * 1024 * 1024
  private static let maximumImageDimension = 4096
  private static let maximumImagePixels = 16 * 1024 * 1024
  private static let defaultTimeout: Duration = .seconds(8)

  static func prepare(
    _ rawURL: String,
    timeout: Duration = defaultTimeout,
    loadMetadata: @escaping MetadataLoader = { url in
      try await RichLinkPreparer.loadMetadata(url)
    },
    stageImage: @escaping ImageStager = { data in
      try RichLinkPreparer.stagePreviewImage(data)
    }
  ) async throws -> PreparedRichLinkPreview {
    let originalURL = try validatedURL(rawURL)
    let fetched: RichLinkFetchedMetadata?
    do {
      fetched = try await fetchWithDeadline(
        originalURL,
        timeout: timeout,
        loadMetadata: loadMetadata
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RichLinkPreparationError where error == .unsupportedPlatform {
      throw error
    } catch {
      fetched = nil
    }

    try Task.checkCancellation()

    let resolvedURL = validatedResolvedURL(fetched?.resolvedURL) ?? originalURL
    let fallbackTitle = originalURL.host ?? originalURL.absoluteString
    let title = sanitizedTitle(fetched?.title, fallback: fallbackTitle)
    let image: PreparedRichLinkPreview.Image?
    do {
      image = try preparedImage(from: fetched?.imageData, stageImage: stageImage)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      image = nil
    }

    let prepared = PreparedRichLinkPreview(
      originalURL: originalURL.absoluteString,
      resolvedURL: resolvedURL.absoluteString,
      title: title,
      image: image
    )
    do {
      try Task.checkCancellation()
    } catch {
      prepared.removeStagedImage()
      throw CancellationError()
    }
    return prepared
  }

  static func validatedURL(_ rawURL: String) throws -> URL {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RichLinkPreparationError.invalidURL("value is empty")
    }
    guard trimmed.utf8.count <= maximumURLBytes else {
      throw RichLinkPreparationError.invalidURL("value exceeds 8 KiB")
    }
    guard var components = URLComponents(string: trimmed) else {
      throw RichLinkPreparationError.invalidURL("value cannot be parsed")
    }
    guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      throw RichLinkPreparationError.invalidURL("scheme must be http or https")
    }
    guard let host = components.host, !host.isEmpty else {
      throw RichLinkPreparationError.invalidURL("host is required")
    }
    guard components.user == nil, components.password == nil else {
      throw RichLinkPreparationError.invalidURL("credentials are not allowed")
    }
    components.scheme = scheme
    guard let url = components.url, url.absoluteString.utf8.count <= maximumURLBytes else {
      throw RichLinkPreparationError.invalidURL("value cannot be normalized")
    }
    return url
  }

  private static func validatedResolvedURL(_ rawURL: String?) -> URL? {
    guard let rawURL else { return nil }
    return try? validatedURL(rawURL)
  }

  private static func sanitizedTitle(_ rawTitle: String?, fallback: String) -> String {
    let candidate = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let source = candidate.isEmpty ? fallback : candidate
    var result = ""
    var byteCount = 0
    for scalar in source.unicodeScalars
    where !CharacterSet.controlCharacters.contains(scalar) {
      let scalarBytes = String(scalar).utf8.count
      guard byteCount + scalarBytes <= maximumTitleBytes else { break }
      result.unicodeScalars.append(scalar)
      byteCount += scalarBytes
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private enum FetchRaceResult: Sendable {
    case fetched(RichLinkFetchedMetadata?)
    case failed(RichLinkPreparationError)
    case timedOut
    case cancelled
  }

  private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FetchRaceResult, Never>?
    private var pending: FetchRaceResult?
    private var completed = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<FetchRaceResult, Never>) {
      lock.lock()
      if completed {
        let pending = pending
        self.pending = nil
        lock.unlock()
        if let pending { continuation.resume(returning: pending) }
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
      lock.lock()
      if completed {
        lock.unlock()
        for task in tasks { task.cancel() }
        return
      }
      self.tasks = tasks
      lock.unlock()
    }

    func complete(_ result: FetchRaceResult) {
      lock.lock()
      guard !completed else {
        lock.unlock()
        return
      }
      completed = true
      let continuation = continuation
      self.continuation = nil
      if continuation == nil { pending = result }
      let tasks = tasks
      self.tasks = []
      lock.unlock()

      for task in tasks { task.cancel() }
      continuation?.resume(returning: result)
    }
  }

  private static func fetchWithDeadline(
    _ url: URL,
    timeout: Duration,
    loadMetadata: @escaping MetadataLoader
  ) async throws -> RichLinkFetchedMetadata? {
    guard timeout > .zero else { return nil }
    let gate = DeadlineGate()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate.install(continuation)
        let loadTask = Task {
          do {
            gate.complete(.fetched(try await loadMetadata(url)))
          } catch is CancellationError {
            if !Task.isCancelled { gate.complete(.cancelled) }
          } catch let error as RichLinkPreparationError {
            gate.complete(.failed(error))
          } catch {
            gate.complete(.fetched(nil))
          }
        }
        let timeoutTask = Task {
          do {
            try await Task.sleep(for: timeout)
            gate.complete(.timedOut)
          } catch {
            // The metadata task completed or the caller cancelled.
          }
        }
        gate.setTasks([loadTask, timeoutTask])
      }
    } onCancel: {
      gate.complete(.cancelled)
    }
    switch result {
    case .fetched(let metadata): return metadata
    case .failed(let error): throw error
    case .timedOut: return nil
    case .cancelled: throw CancellationError()
    }
  }

  private static func preparedImage(
    from data: Data?,
    stageImage: ImageStager
  ) throws -> PreparedRichLinkPreview.Image? {
    #if os(macOS)
      guard let data, !data.isEmpty, data.count <= maximumImageBytes else { return nil }
      guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetCount(source) == 1,
        let typeIdentifier = CGImageSourceGetType(source) as String?,
        let mimeType = UTType(typeIdentifier)?.preferredMIMEType?.lowercased(),
        ["image/jpeg", "image/png", "image/webp"].contains(mimeType),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0,
        height > 0,
        width <= maximumImageDimension,
        height <= maximumImageDimension,
        height <= maximumImagePixels / width,
        let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
        decodedImage.dataProvider?.data != nil
      else {
        return nil
      }

      let stagedPath = try stageImage(data)
      let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return PreparedRichLinkPreview.Image(
        filePath: stagedPath,
        mimeType: mimeType,
        contentHash: contentHash,
        byteCount: data.count,
        pixelWidth: width,
        pixelHeight: height
      )
    #else
      _ = data
      return nil
    #endif
  }

}
