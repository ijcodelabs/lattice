import Foundation

/// One line of a JSONL trace. Flat on purpose: easy to grep, diff and later replay into the reducer.
public struct TraceEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appLaunched, appTerminated, appActivated
        case windowCreated, windowDestroyed, windowMoved, windowResized, windowFocused, windowMinimized, windowDeminimized
        case setFrame, getFrame, axTimeout, axError
        case displaysChanged, sleep, wake
        case note
    }

    /// Seconds since the trace started.
    public var t: Double
    public var kind: Kind
    public var pid: Int32?
    public var app: String?
    public var window: String?
    public var title: String?
    public var frame: Rect?
    public var requested: Rect?
    public var outcome: FrameOutcome?
    public var latencyMs: Double?
    public var axError: Int32?
    public var detail: String?

    public init(
        t: Double, kind: Kind, pid: Int32? = nil, app: String? = nil, window: String? = nil, title: String? = nil,
        frame: Rect? = nil, requested: Rect? = nil, outcome: FrameOutcome? = nil, latencyMs: Double? = nil,
        axError: Int32? = nil, detail: String? = nil
    ) {
        self.t = t; self.kind = kind; self.pid = pid; self.app = app; self.window = window; self.title = title
        self.frame = frame; self.requested = requested; self.outcome = outcome; self.latencyMs = latencyMs
        self.axError = axError; self.detail = detail
    }
}

/// Thread-safe JSONL writer.
public final class TraceWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let start = Date()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    public let url: URL

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.url = url
        self.handle = try FileHandle(forWritingTo: url)
    }

    public var elapsed: Double { Date().timeIntervalSince(start) }

    public func write(_ event: TraceEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        handle.write(line)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.close()
    }

    public static func read(_ url: URL) throws -> [TraceEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        return try text.split(separator: "\n").map { try dec.decode(TraceEvent.self, from: Data($0.utf8)) }
    }
}
