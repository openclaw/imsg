import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum AttachmentSource {
  static func openFile(at path: String) throws -> FileHandle {
    let components = (path as NSString).pathComponents
    guard components.first == "/", components.count > 1, let filename = components.last else {
      throw IMsgError.appleScriptFailure("Invalid attachment path")
    }

    var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryFD >= 0 else {
      throw openError(path: path)
    }
    defer { close(directoryFD) }

    for component in components.dropFirst().dropLast() where component != "/" {
      let nextFD = openat(
        directoryFD,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard nextFD >= 0 else {
        throw openError(path: path)
      }
      close(directoryFD)
      directoryFD = nextFD
    }

    let sourceFD = openat(
      directoryFD,
      filename,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard sourceFD >= 0 else {
      throw openError(path: path)
    }

    var info = stat()
    guard fstat(sourceFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(sourceFD)
      throw IMsgError.appleScriptFailure("Attachment must be a regular file")
    }
    return FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
  }

  static func copy(_ source: FileHandle, to destination: URL) throws {
    let destinationFD = destination.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard destinationFD >= 0 else {
      throw IMsgError.appleScriptFailure("Could not create staged attachment")
    }
    let destinationHandle = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: true)
    defer { try? destinationHandle.close() }

    #if canImport(Darwin)
      guard
        fcopyfile(
          source.fileDescriptor,
          destinationFD,
          nil,
          copyfile_flags_t(COPYFILE_ALL)
        ) == 0
      else {
        throw openError(path: destination.path)
      }
    #else
      while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        try destinationHandle.write(contentsOf: chunk)
      }
      var info = stat()
      if fstat(source.fileDescriptor, &info) == 0 {
        _ = fchmod(destinationFD, info.st_mode & 0o777)
      }
    #endif
  }

  private static func openError(path: String) -> IMsgError {
    let code = errno
    if code == ENOENT {
      return .appleScriptFailure("Attachment not found at \(path)")
    }
    return .appleScriptFailure(
      "Could not securely open attachment at \(path): \(String(cString: strerror(code)))"
    )
  }
}
