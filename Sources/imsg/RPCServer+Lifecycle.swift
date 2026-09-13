import Foundation
import IMsgCore

extension RPCServer {
  func run() async throws {
    try await run(lines: RPCLineSource.standardInput())
  }

  func run(lines: RPCLineStream) async throws {
    let scheduler = RPCScheduler(server: self)
    try await withTaskCancellationHandler {
      try await run(lines: lines, scheduler: scheduler)
    } onCancel: {
      Task.detached { [subscriptions] in
        await scheduler.stopAdmissionAndCancelReadControl()
        await subscriptions.cancelAll()
      }
    }
  }

  private func run(lines: RPCLineStream, scheduler: RPCScheduler) async throws {
    var sourceError: Error?
    do {
      for try await line in lines {
        try Task.checkCancellation()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        await scheduler.submit(trimmed)
      }
    } catch {
      sourceError = error
    }

    let cancelled = Task.isCancelled || sourceError is CancellationError
    if cancelled || sourceError != nil {
      await scheduler.stopAdmissionAndCancelReadControl()
    } else {
      await scheduler.stopAdmission()
    }
    // EOF and cancellation stop live producers before accepted request drain.
    await subscriptions.cancelAll()
    await scheduler.waitUntilDrained()
    output.flush()

    if let sourceError {
      throw sourceError
    }
    if cancelled || Task.isCancelled {
      throw CancellationError()
    }
  }

}
