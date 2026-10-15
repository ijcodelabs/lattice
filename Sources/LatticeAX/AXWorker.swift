import Foundation

/// A dedicated thread + run loop for one app's AX traffic.
///
/// AX calls are synchronous cross-process IPC; a hung app blocks the calling thread for the whole
/// messaging timeout. One worker per app means a hung app can only ever stall its own worker.
/// `sync` additionally bounds how long the *caller* waits, and refuses new work while a call is stuck
/// (watchdog), so callers never pile up behind a dead app.
public final class AXWorker: Thread, @unchecked Sendable {
    public let label: String
    private var cfRunLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlightSince: Date?

    public init(label: String) {
        self.label = label
        super.init()
        name = "lattice.ax.\(label)"
        qualityOfService = .userInteractive
    }

    /// Starts the thread and returns once its run loop is ready.
    public func startAndWait() {
        start()
        ready.wait()
    }

    public override func main() {
        cfRunLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive with no other sources attached.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// The worker's run loop — AX observers must be scheduled on it.
    public var runLoop: CFRunLoop {
        guard let cfRunLoop else { preconditionFailure("AXWorker \(label) not started") }
        return cfRunLoop
    }

    /// Seconds the current call has been running, nil when idle.
    public var stuckFor: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return inFlightSince.map { Date().timeIntervalSince($0) }
    }

    public func async(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    public enum SyncError: Error, CustomStringConvertible {
        case timeout(label: String, seconds: TimeInterval)
        case busy(label: String, stuckFor: TimeInterval)

        public var description: String {
            switch self {
            case let .timeout(l, s): "AX worker \(l) timed out after \(String(format: "%.2f", s))s"
            case let .busy(l, s): "AX worker \(l) still stuck on a previous call (\(String(format: "%.1f", s))s)"
            }
        }
    }

    /// Run `body` on the worker and wait at most `timeout` seconds for the result.
    /// If a previous call is still running, wait up to `waitIfBusy` seconds for it before refusing
    /// (use for must-run work like restores; leave 0 for everything else so callers never pile up).
    public func sync<T>(
        timeout: TimeInterval = 1.0, waitIfBusy: TimeInterval = 0, _ body: @escaping @Sendable () -> T
    ) throws(SyncError) -> T {
        let deadline = Date().addingTimeInterval(waitIfBusy)
        while let stuck = stuckFor {
            guard Date() < deadline else { throw .busy(label: label, stuckFor: stuck) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        async { [self] in
            setInFlight(true)
            box.value = body()
            setInFlight(false)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw .timeout(label: label, seconds: timeout)
        }
        return box.value!
    }

    private func setInFlight(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        inFlightSince = on ? Date() : nil
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
