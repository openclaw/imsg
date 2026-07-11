import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import imsg

private final class RichLinkTestBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

@Test
func richLinkPreparerRejectsUnsafeURLs() async {
  let tooLong = "https://example.com/" + String(repeating: "a", count: 8 * 1024)
  for rawURL in [
    "",
    "ftp://example.com/file",
    "https:///missing-host",
    "https://user:secret@example.com/private",
    tooLong,
  ] {
    do {
      _ = try await RichLinkPreparer.prepare(rawURL, loadMetadata: { _ in nil })
      Issue.record("expected URL rejection for \(rawURL.prefix(40))")
    } catch is RichLinkPreparationError {
      // Expected.
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}

@Test
func richLinkPreparerUsesBoundedMetadataOnlyFallback() async throws {
  let prepared = try await RichLinkPreparer.prepare(
    "HTTPS://Example.com/path",
    loadMetadata: { _ in
      throw CocoaError(.fileReadUnknown)
    }
  )

  #expect(prepared.originalURL == "https://Example.com/path")
  #expect(prepared.resolvedURL == "https://Example.com/path")
  #expect(prepared.title == "Example.com")
  #expect(prepared.image == nil)
}

@Test
func richLinkPreparerPropagatesUnsupportedPlatformError() async {
  do {
    _ = try await RichLinkPreparer.prepare(
      "https://example.com",
      loadMetadata: { _ in
        throw RichLinkPreparationError.unsupportedPlatform
      }
    )
    Issue.record("expected unsupported-platform error")
  } catch let error as RichLinkPreparationError {
    #expect(error == .unsupportedPlatform)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test
func richLinkPreparerSanitizesFetchedMetadataAndValidatesImage() async throws {
  let png = try makeRichLinkPNG(width: 3, height: 2)
  let prepared = try await RichLinkPreparer.prepare(
    "https://example.com/original",
    loadMetadata: { _ in
      RichLinkFetchedMetadata(
        resolvedURL: "https://example.com/resolved",
        title: "  Example\nTitle  ",
        imageData: png
      )
    },
    stageImage: { _ in "/tmp/test.pluginPayloadAttachment" }
  )

  #expect(prepared.resolvedURL == "https://example.com/resolved")
  #expect(prepared.title == "ExampleTitle")
  #expect(prepared.image?.mimeType == "image/png")
  #expect(prepared.image?.pixelWidth == 3)
  #expect(prepared.image?.pixelHeight == 2)
  #expect(prepared.image?.byteCount == png.count)
}

@Test
func richLinkPreparerDropsMalformedAndOversizedImages() async throws {
  let oversized = Data(repeating: 0, count: 2 * 1024 * 1024 + 1)
  let unsupportedTIFF = try makeRichLinkTIFF(width: 3, height: 2)
  for imageData in [Data([0x89, 0x50, 0x4E]), oversized, unsupportedTIFF] {
    let staged = RichLinkTestBox(false)
    let prepared = try await RichLinkPreparer.prepare(
      "https://example.com",
      loadMetadata: { _ in RichLinkFetchedMetadata(imageData: imageData) },
      stageImage: { _ in
        staged.withValue { $0 = true }
        return "/tmp/should-not-stage.pluginPayloadAttachment"
      }
    )
    #expect(prepared.image == nil)
    #expect(staged.withValue { $0 } == false)
  }
}

@Test
func richLinkPreparerDropsMultiFrameImages() async throws {
  let animatedPNG = try makeMultiFrameRichLinkPNG(width: 3, height: 2)
  let source = try #require(CGImageSourceCreateWithData(animatedPNG as CFData, nil))
  #expect(CGImageSourceGetCount(source) == 2)

  let staged = RichLinkTestBox(false)
  let prepared = try await RichLinkPreparer.prepare(
    "https://example.com",
    loadMetadata: { _ in RichLinkFetchedMetadata(imageData: animatedPNG) },
    stageImage: { _ in
      staged.withValue { $0 = true }
      return "/tmp/should-not-stage.pluginPayloadAttachment"
    }
  )

  #expect(prepared.image == nil)
  #expect(staged.withValue { $0 } == false)
}

@Test
func richLinkPreparerCancellationDoesNotWaitForCancellationIgnoringLoader() async throws {
  typealias Continuation = CheckedContinuation<RichLinkFetchedMetadata?, Never>
  let continuation = RichLinkTestBox<Continuation?>(nil)
  let loaderStarted = RichLinkTestBox(false)
  let staged = RichLinkTestBox(false)
  let task = Task {
    try await RichLinkPreparer.prepare(
      "https://example.com",
      loadMetadata: { _ in
        return await withCheckedContinuation { pending in
          continuation.withValue { $0 = pending }
          loaderStarted.withValue { $0 = true }
        }
      },
      stageImage: { _ in
        staged.withValue { $0 = true }
        return "/tmp/should-not-stage.pluginPayloadAttachment"
      }
    )
  }

  let clock = ContinuousClock()
  let waitDeadline = clock.now.advanced(by: .seconds(1))
  while !loaderStarted.withValue({ $0 }), clock.now < waitDeadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(loaderStarted.withValue { $0 })

  let cancelledAt = clock.now
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("expected cancellation")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  let elapsed = cancelledAt.duration(to: clock.now)
  continuation.withValue { pending in
    pending?.resume(returning: nil)
    pending = nil
  }

  #expect(elapsed < .seconds(1))
  #expect(staged.withValue { $0 } == false)
}

@Test
func richLinkPreparerPropagatesCancellationDuringImageStaging() async throws {
  let png = try makeRichLinkPNG(width: 3, height: 2)
  let staged = RichLinkTestBox(false)
  let task = Task {
    try await RichLinkPreparer.prepare(
      "https://example.com",
      loadMetadata: { _ in RichLinkFetchedMetadata(imageData: png) },
      stageImage: { _ in
        staged.withValue { $0 = true }
        withUnsafeCurrentTask { $0?.cancel() }
        return "/tmp/cancelled.pluginPayloadAttachment"
      }
    )
  }

  do {
    _ = try await task.value
    Issue.record("expected cancellation after image staging")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  #expect(staged.withValue { $0 })
}

@Test
func richLinkPreparerDeadlineDoesNotWaitForCancellationIgnoringLoader() async throws {
  typealias Continuation = CheckedContinuation<RichLinkFetchedMetadata?, Never>
  let continuation = RichLinkTestBox<Continuation?>(nil)
  let clock = ContinuousClock()
  let started = clock.now

  let prepared = try await RichLinkPreparer.prepare(
    "https://example.com",
    timeout: .milliseconds(30),
    loadMetadata: { _ in
      await withCheckedContinuation { pending in
        continuation.withValue { $0 = pending }
      }
    }
  )
  let elapsed = started.duration(to: clock.now)
  continuation.withValue { pending in
    pending?.resume(returning: nil)
    pending = nil
  }

  #expect(elapsed < .seconds(1))
  #expect(prepared.image == nil)
  #expect(prepared.title == "example.com")
}

private func makeRichLinkPNG(width: Int, height: Int) throws -> Data {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  )
  return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func makeRichLinkTIFF(width: Int, height: Int) throws -> Data {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  )
  return try #require(bitmap.tiffRepresentation)
}

private func makeMultiFrameRichLinkPNG(width: Int, height: Int) throws -> Data {
  let frameData = try makeRichLinkPNG(width: width, height: height)
  let source = try #require(CGImageSourceCreateWithData(frameData as CFData, nil))
  let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  let output = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      2,
      nil
    )
  )
  CGImageDestinationAddImage(destination, frame, nil)
  CGImageDestinationAddImage(destination, frame, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return output as Data
}
