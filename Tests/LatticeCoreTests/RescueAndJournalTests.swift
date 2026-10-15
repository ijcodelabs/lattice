import Foundation
import Testing
@testable import LatticeCore

@Suite struct RescueTests {
    let displays = [laptop, external]

    @Test func onScreenWindowIsNotStranded() {
        #expect(!Rescue.isStranded(Rect(x: 100, y: 100, width: 800, height: 600), displays: displays))
        // Spanning both displays is fine.
        #expect(!Rescue.isStranded(Rect(x: 1200, y: 100, width: 800, height: 600), displays: displays))
    }

    @Test func parkedWindowsAreStranded() throws {
        for strategy in ParkingStrategy.allCases {
            let plan = try #require(Parking.plan(size: window, home: laptop, displays: displays, strategy: strategy))
            #expect(Rescue.isStranded(plan.frame, displays: displays))
        }
    }

    @Test func thinVisibleStripIsStranded() {
        // 50pt-wide strip visible on the right edge of the external display: too small to grab.
        #expect(Rescue.isStranded(Rect(x: 4022, y: 100, width: 800, height: 600), displays: displays))
    }

    @Test func windowOnUnpluggedDisplayIsRescuedToPrimary() throws {
        let orphan = Rect(x: 2000, y: 200, width: 3000, height: 2000)
        #expect(Rescue.isStranded(orphan, displays: [laptop]))
        let target = try #require(Rescue.rescueFrame(for: orphan, displays: [laptop]))
        #expect(target.width <= laptop.visibleFrame.width * 0.9 + 0.001)
        #expect(target.height <= laptop.visibleFrame.height * 0.9 + 0.001)
        #expect(target.intersection(laptop.visibleFrame)?.area == target.area)
        #expect(!Rescue.isStranded(target, displays: [laptop]))
    }

    @Test func emptyDisplayListNeverClaimsStranded() {
        #expect(!Rescue.isStranded(Rect(x: 0, y: 0, width: 10, height: 10), displays: []))
        #expect(Rescue.rescueFrame(for: Rect(x: 0, y: 0, width: 10, height: 10), displays: []) == nil)
    }
}

@Suite struct JournalTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lattice-test-\(UUID().uuidString)/journal.json")
    }

    @Test func roundTripAndDedupe() throws {
        let url = tempURL()
        var j = ParkJournal()
        let a = ParkJournal.Entry(pid: 1, app: "A", title: "w", windowKey: "1:a", original: Rect(x: 1, y: 2, width: 3, height: 4))
        j.record(a)
        j.record(a) // same key replaces
        #expect(j.entries.count == 1)
        try j.save(to: url)
        #expect(ParkJournal.load(from: url).entries == [a])
    }

    @Test func emptyJournalRemovesFile() throws {
        let url = tempURL()
        var j = ParkJournal(entries: [.init(pid: 1, app: "A", title: "", windowKey: "k", original: Rect(x: 0, y: 0, width: 1, height: 1))])
        try j.save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        j.remove(windowKey: "k")
        try j.save(to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingOrCorruptJournalLoadsEmpty() throws {
        let url = tempURL()
        #expect(ParkJournal.load(from: url).entries.isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(ParkJournal.load(from: url).entries.isEmpty)
    }
}

@Suite struct TraceTests {
    @Test func jsonlRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-trace-\(UUID().uuidString).jsonl")
        let w = try TraceWriter(url: url)
        let e1 = TraceEvent(t: 0.5, kind: .setFrame, pid: 42, app: "Safari", window: "42:ff",
                            frame: Rect(x: 1, y: 2, width: 3, height: 4), outcome: .clamped, latencyMs: 3.2)
        let e2 = TraceEvent(t: 1.0, kind: .wake)
        w.write(e1)
        w.write(e2)
        w.close()
        #expect(try TraceWriter.read(url) == [e1, e2])
    }
}
