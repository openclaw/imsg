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

private final class StdoutPipeReader: @unchecked Sendable {
  struct Result {
    let data: Data
    let errorNumber: Int32?
  }

  private let condition = NSCondition()
  private let readFD: Int32
  private var isStarted = false
  private var result: Result?

  init(readFD: Int32) {
    self.readFD = readFD
  }

  func startAndWaitUntilReady() {
    condition.lock()
    Thread { [self] in
      condition.lock()
      isStarted = true
      condition.broadcast()
      condition.unlock()

      var data = Data()
      var errorNumber: Int32?
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = read(readFD, &buffer, buffer.count)
        if count > 0 {
          data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
          break
        } else if errno != EINTR {
          errorNumber = errno
          break
        }
      }
      close(readFD)

      condition.lock()
      result = Result(data: data, errorNumber: errorNumber)
      condition.broadcast()
      condition.unlock()
    }.start()

    while !isStarted {
      condition.wait()
    }
    condition.unlock()
  }

  func waitForResult() -> Result {
    condition.lock()
    while result == nil {
      condition.wait()
    }
    let completed = result!
    condition.unlock()
    return completed
  }
}

enum StdoutCapture {
  private static let lock = StdoutCaptureLock()

  private static func finish(
    savedStdout: Int32,
    reader: StdoutPipeReader
  ) -> (readerResult: StdoutPipeReader.Result, restored: Bool) {
    fflush(nil)
    let restored = dup2(savedStdout, STDOUT_FILENO) >= 0
    if !restored {
      close(STDOUT_FILENO)
    }
    close(savedStdout)
    return (reader.waitForResult(), restored)
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

    let reader = StdoutPipeReader(readFD: readFD)
    reader.startAndWaitUntilReady()

    guard dup2(writeFD, STDOUT_FILENO) >= 0 else {
      close(writeFD)
      close(savedStdout)
      let readerResult = reader.waitForResult()
      await lock.release()
      guard readerResult.errorNumber == nil else {
        fatalError("read(readFD) failed with errno \(readerResult.errorNumber!)")
      }
      fatalError("dup2(writeFD, STDOUT_FILENO) failed")
    }
    close(writeFD)

    do {
      let value = try await body()
      let result = finish(savedStdout: savedStdout, reader: reader)
      await lock.release()
      guard result.restored else {
        fatalError("dup2(savedStdout, STDOUT_FILENO) failed")
      }
      guard result.readerResult.errorNumber == nil else {
        fatalError("read(readFD) failed with errno \(result.readerResult.errorNumber!)")
      }
      return (String(data: result.readerResult.data, encoding: .utf8) ?? "", value)
    } catch {
      let result = finish(savedStdout: savedStdout, reader: reader)
      await lock.release()
      guard result.restored else {
        fatalError("dup2(savedStdout, STDOUT_FILENO) failed")
      }
      guard result.readerResult.errorNumber == nil else {
        fatalError("read(readFD) failed with errno \(result.readerResult.errorNumber!)")
      }
      throw error
    }
  }
}
