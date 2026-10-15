import Foundation

/// Write-ahead journal of original frames. Written **before** a window is parked, so `rescue`
/// can restore it even if the process crashes mid-experiment.
public struct ParkJournal: Codable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var pid: Int32
        public var app: String
        public var title: String
        public var windowKey: String
        public var original: Rect

        public init(pid: Int32, app: String, title: String, windowKey: String, original: Rect) {
            self.pid = pid; self.app = app; self.title = title; self.windowKey = windowKey; self.original = original
        }
    }

    public var entries: [Entry] = []
    public init(entries: [Entry] = []) { self.entries = entries }

    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.windowKey == entry.windowKey }
        entries.append(entry)
    }

    public mutating func remove(windowKey: String) { entries.removeAll { $0.windowKey == windowKey } }

    // MARK: - Persistence

    public static func load(from url: URL) -> ParkJournal {
        guard let data = try? Data(contentsOf: url) else { return ParkJournal() }
        return (try? JSONDecoder().decode(ParkJournal.self, from: data)) ?? ParkJournal()
    }

    /// Atomic write; removes the file when empty.
    public func save(to url: URL) throws {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

public enum LatticePaths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lattice", isDirectory: true)
    }
    public static var journal: URL { supportDir.appendingPathComponent("park-journal.json") }
    public static var traces: URL { supportDir.appendingPathComponent("traces", isDirectory: true) }
    /// The saved layout (session restore).
    public static var session: URL { supportDir.appendingPathComponent("session.json") }
}
