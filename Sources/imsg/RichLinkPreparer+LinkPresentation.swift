import Foundation
import IMsgCore

#if os(macOS)
  @preconcurrency import LinkPresentation
#endif

extension RichLinkPreparer {
  #if os(macOS)
    static func stagePreviewImage(_ data: Data) throws -> String {
      let fileManager = FileManager.default
      let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "imsg-rich-link-\(UUID().uuidString)",
        isDirectory: true
      )
      try fileManager.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false
      )
      defer { try? fileManager.removeItem(at: temporaryDirectory) }

      let source = temporaryDirectory.appendingPathComponent(
        "\(UUID().uuidString).pluginPayloadAttachment",
        isDirectory: false
      )
      try data.write(to: source, options: .atomic)
      return try MessageSender.stageAttachmentForMessagesApp(at: source.path)
    }

    static func loadMetadata(_ url: URL) async throws -> RichLinkFetchedMetadata? {
      let providerBox = MetadataProviderBox()
      providerBox.provider.timeout = 8
      providerBox.provider.shouldFetchSubresources = true
      let metadata = try await fetchMetadata(url, providerBox: providerBox)
      guard let metadata else { return nil }

      var imageData: Data?
      for itemProvider in [metadata.imageProvider, metadata.iconProvider].compactMap({ $0 }) {
        if let loaded = try await loadImageData(from: itemProvider) {
          imageData = loaded
          break
        }
      }
      return RichLinkFetchedMetadata(
        resolvedURL: metadata.url?.absoluteString,
        title: metadata.title,
        imageData: imageData
      )
    }

    private enum MetadataCallbackResult: @unchecked Sendable {
      case value(LPLinkMetadata?)
      case cancelled
    }

    private enum ImageCallbackResult: Sendable {
      case value(Data?)
      case cancelled
    }

    private final class MetadataProviderBox: @unchecked Sendable {
      let provider = LPMetadataProvider()
    }

    private final class ProgressBox: @unchecked Sendable {
      let progress: Progress

      init(_ progress: Progress) {
        self.progress = progress
      }
    }

    private final class OneShot<Value: Sendable>: @unchecked Sendable {
      private let lock = NSLock()
      private var continuation: CheckedContinuation<Value, Never>?
      private var pendingValue: Value?
      private var completed = false
      private var cancellation: (@Sendable () -> Void)?

      func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if completed {
          let value = pendingValue
          pendingValue = nil
          lock.unlock()
          if let value { continuation.resume(returning: value) }
          return
        }
        self.continuation = continuation
        lock.unlock()
      }

      func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        if completed {
          lock.unlock()
          cancellation()
          return
        }
        self.cancellation = cancellation
        lock.unlock()
      }

      func complete(_ value: Value, cancelOperation: Bool = false) {
        lock.lock()
        guard !completed else {
          lock.unlock()
          return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingValue = value }
        let cancellation = cancelOperation ? self.cancellation : nil
        self.cancellation = nil
        lock.unlock()

        cancellation?()
        continuation?.resume(returning: value)
      }
    }

    private static func fetchMetadata(
      _ url: URL,
      providerBox: MetadataProviderBox
    ) async throws -> LPLinkMetadata? {
      let gate = OneShot<MetadataCallbackResult>()
      let result = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          gate.install(continuation)
          providerBox.provider.startFetchingMetadata(for: url) { metadata, _ in
            gate.complete(.value(metadata))
          }
          gate.setCancellation { providerBox.provider.cancel() }
        }
      } onCancel: {
        gate.complete(.cancelled, cancelOperation: true)
      }
      switch result {
      case .value(let metadata): return metadata
      case .cancelled: throw CancellationError()
      }
    }

    private static func loadImageData(from provider: NSItemProvider) async throws -> Data? {
      let candidates = [
        "public.jpeg",
        "public.png",
        "org.webmproject.webp",
        "public.image",
      ]
      for typeIdentifier in candidates
      where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
        let gate = OneShot<ImageCallbackResult>()
        let result = await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            gate.install(continuation)
            let progress = provider.loadFileRepresentation(
              forTypeIdentifier: typeIdentifier
            ) { fileURL, _ in
              guard let fileURL else {
                gate.complete(.value(nil))
                return
              }
              let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
              guard let fileSize, fileSize <= maximumImageBytes else {
                gate.complete(.value(nil))
                return
              }
              gate.complete(.value(try? Data(contentsOf: fileURL)))
            }
            let progressBox = ProgressBox(progress)
            gate.setCancellation { progressBox.progress.cancel() }
          }
        } onCancel: {
          gate.complete(.cancelled, cancelOperation: true)
        }
        switch result {
        case .value(let data):
          if let data, !data.isEmpty { return data }
        case .cancelled:
          throw CancellationError()
        }
      }
      return nil
    }
  #else
    static func stagePreviewImage(_ data: Data) throws -> String {
      _ = data
      throw RichLinkPreparationError.unsupportedPlatform
    }

    static func loadMetadata(_ url: URL) async throws -> RichLinkFetchedMetadata? {
      _ = url
      throw RichLinkPreparationError.unsupportedPlatform
    }
  #endif
}
