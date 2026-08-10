import Darwin
import Foundation

private actor StdoutCaptureLock {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
      return
    }
    let next = waiters.removeFirst()
    next.resume()
  }
}

enum StdoutCapture {
  private static let lock = StdoutCaptureLock()

  private static func finish(
    savedStdout: Int32,
    reader: Task<Data, Never>
  ) async -> (data: Data, restored: Bool) {
    fflush(nil)
    let restored = dup2(savedStdout, STDOUT_FILENO) >= 0
    if !restored {
      close(STDOUT_FILENO)
    }
    close(savedStdout)
    return (await reader.value, restored)
  }

  static func capture<T>(_ body: () async throws -> T) async rethrows -> (output: String, value: T)
  {
    await lock.acquire()

    fflush(nil)

    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
      await lock.release()
      fatalError("pipe() failed")
    }
    let readFD = fds[0]
    let writeFD = fds[1]

    let savedStdout = dup(STDOUT_FILENO)
    guard savedStdout >= 0 else {
      close(readFD)
      close(writeFD)
      await lock.release()
      fatalError("dup(STDOUT_FILENO) failed")
    }

    guard dup2(writeFD, STDOUT_FILENO) >= 0 else {
      close(readFD)
      close(writeFD)
      close(savedStdout)
      await lock.release()
      fatalError("dup2(writeFD, STDOUT_FILENO) failed")
    }
    close(writeFD)

    let reader = Task.detached(priority: .high) {
      let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
      defer { handle.closeFile() }
      return handle.readDataToEndOfFile()
    }

    do {
      let value = try await body()
      let result = await finish(savedStdout: savedStdout, reader: reader)
      await lock.release()
      guard result.restored else {
        fatalError("dup2(savedStdout, STDOUT_FILENO) failed")
      }
      return (String(data: result.data, encoding: .utf8) ?? "", value)
    } catch {
      let result = await finish(savedStdout: savedStdout, reader: reader)
      await lock.release()
      guard result.restored else {
        fatalError("dup2(savedStdout, STDOUT_FILENO) failed")
      }
      throw error
    }
  }
}
