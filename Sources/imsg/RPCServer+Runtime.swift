import Foundation

typealias RPCLineStream = AsyncThrowingStream<String, Error>

enum RPCLineSource {
  static func standardInput() -> RPCLineStream {
    RPCLineStream { continuation in
      // This process-lifetime thread exclusively owns blocking stdin reads. Cancellation stops
      // stream consumption but does not close process-global stdin; command exit reclaims it.
      let thread = Thread {
        while let line = readLine() {
          continuation.yield(line)
        }
        continuation.finish()
      }
      thread.name = "imsg.rpc.stdin"
      thread.start()
    }
  }
}

private enum RPCRequestLane: Sendable {
  case mutation
  case read
  case control
}

private let rpcReadMethods: Set<String> = [
  "chats.list",
  "messages.history",
  "messages.stats",
  "messages.after",
  "messages.scheduled",
  "message.send_status",
  "handles.check",
  "contacts.shouldShareContact",
]

private let rpcControlMethods: Set<String> = [
  "watch.subscribe",
  "watch.unsubscribe",
]

actor RPCScheduler {
  private let server: RPCServer
  private let outstandingLimit: Int
  private let readLimit: Int

  private var accepting = true
  private var outstanding = 0
  private var nextTaskID: UInt64 = 1
  private var mutationQueue: [String] = []
  private var readQueue: [String] = []
  private var controlQueue: [String] = []
  private var mutationWorker: Task<Void, Never>?
  private var controlWorker: Task<Void, Never>?
  private var readTasks: [UInt64: Task<Void, Never>] = [:]
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  init(server: RPCServer, outstandingLimit: Int = 128, readLimit: Int = 4) {
    self.server = server
    self.outstandingLimit = outstandingLimit
    self.readLimit = readLimit
  }

  func submit(_ line: String) {
    guard accepting else { return }
    guard outstanding < outstandingLimit else {
      server.rejectBusy(line)
      return
    }

    outstanding += 1
    switch lane(for: line) {
    case .mutation:
      mutationQueue.append(line)
      startMutationWorkerIfNeeded()
    case .read:
      readQueue.append(line)
      startReadsIfPossible()
    case .control:
      startControl(line)
    }
  }

  func stopAdmission() {
    accepting = false
  }

  func stopAdmissionAndCancelReadControl() {
    accepting = false
    outstanding -= readQueue.count
    readQueue.removeAll()
    for task in readTasks.values {
      task.cancel()
    }
    outstanding -= controlQueue.count
    controlQueue.removeAll()
    controlWorker?.cancel()
    resumeDrainWaitersIfNeeded()
  }

  func waitUntilDrained() async {
    guard outstanding > 0 else { return }
    await withCheckedContinuation { continuation in
      drainWaiters.append(continuation)
    }
  }

  var outstandingCountForTesting: Int {
    outstanding
  }

  private func lane(for line: String) -> RPCRequestLane {
    guard case .success(let request) = RPCRequestParser.parse(line) else {
      return .control
    }
    if rpcReadMethods.contains(request.method) {
      return .read
    }
    if rpcControlMethods.contains(request.method) || !kSupportedRPCMethods.contains(request.method)
    {
      return .control
    }
    return .mutation
  }

  private func startMutationWorkerIfNeeded() {
    guard mutationWorker == nil else { return }
    mutationWorker = Task.detached { [server] in
      while let line = await self.takeNextMutation() {
        // A single worker owns the entire mutation lifecycle, including its response.
        await server.handleLine(line)
        await self.completeMutation()
      }
    }
  }

  private func takeNextMutation() -> String? {
    guard !mutationQueue.isEmpty else {
      mutationWorker = nil
      return nil
    }
    return mutationQueue.removeFirst()
  }

  private func completeMutation() {
    outstanding -= 1
    resumeDrainWaitersIfNeeded()
  }

  private func startReadsIfPossible() {
    while readTasks.count < readLimit, !readQueue.isEmpty {
      let line = readQueue.removeFirst()
      let taskID = allocateTaskID()
      let task = Task.detached { [server] in
        await server.handleLine(line)
        await self.completeRead(taskID)
      }
      readTasks[taskID] = task
    }
  }

  private func completeRead(_ taskID: UInt64) {
    guard readTasks.removeValue(forKey: taskID) != nil else { return }
    outstanding -= 1
    startReadsIfPossible()
    resumeDrainWaitersIfNeeded()
  }

  private func startControl(_ line: String) {
    controlQueue.append(line)
    guard controlWorker == nil else { return }
    controlWorker = Task.detached { [server] in
      while let line = await self.takeNextControl() {
        await server.handleLine(line)
        await self.completeControl()
      }
    }
  }

  private func takeNextControl() -> String? {
    guard !Task.isCancelled, !controlQueue.isEmpty else {
      controlWorker = nil
      return nil
    }
    return controlQueue.removeFirst()
  }

  private func completeControl() {
    outstanding -= 1
    resumeDrainWaitersIfNeeded()
  }

  private func allocateTaskID() -> UInt64 {
    defer { nextTaskID += 1 }
    return nextTaskID
  }

  private func resumeDrainWaitersIfNeeded() {
    guard outstanding == 0 else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
