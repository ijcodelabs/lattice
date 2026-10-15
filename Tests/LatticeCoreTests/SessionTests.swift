import Foundation
import Testing
@testable import LatticeCore

func win(_ id: String, app: String, title: String, x: Double = 100) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), pid: 1, app: app, bundleID: "com.example.\(app.lowercased())", title: title,
                   frame: Rect(x: x, y: 100, width: 600, height: 400))
}

@Suite struct SessionTests {
    /// A session worth restoring: workspace 1 = Safari | (Mail grouped with Notes) in tree layout,
    /// workspace 2 = Ghostty. Returns the engine and its snapshot.
    func arranged() -> (Engine, SessionSnapshot) {
        var e = engine()
        _ = e.handle([.windowAdded(win("s1", app: "Safari", title: "Apple")),
                      .windowAdded(win("m1", app: "Mail", title: "Inbox – Mail")),
                      .windowAdded(win("g1", app: "Ghostty", title: "zsh"))], now: 0)
        _ = e.handle(.command(.moveToWorkspace("2", follow: false)), now: 1)   // Ghostty → 2
        _ = e.handle(.command(.layout(.tree)), now: 2)
        _ = e.handle(.command(.focusWindow(WindowID("m1"))), now: 3)
        _ = e.handle(.command(.group(nil)), now: 4)                            // Mail in a group of one
        _ = e.handle(.windowAdded(win("n1", app: "Notes", title: "Shopping")), now: 5)   // joins Mail's group
        return (e, e.snapshot(savedAt: 1000)!)
    }

    /// The same apps come back with brand-new window ids (and different frames), as after a reboot.
    let comeBack = [win("S", app: "Safari", title: "Apple", x: 900), win("M", app: "Mail", title: "Inbox (2) – Mail", x: 50),
                    win("N", app: "Notes", title: "Shopping"), win("G", app: "Ghostty", title: "zsh")]

    @Test func snapshotRoundTripsThroughJSON() throws {
        let (_, snap) = arranged()
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: data) == snap)
        #expect(snap.windows.count == 4 && snap.active == "1")
    }

    @Test func fullRestoreRebuildsLayoutGroupsAndWorkspaces() {
        let (old, snap) = arranged()
        var e = engine()
        _ = e.handle([.restoreSession(snap, until: 60)] + comeBack.map(Event.windowAdded), now: 0)
        #expect(e.restoring == nil)                                   // everything matched → done
        let ws1 = e.workspaces["1"]!
        #expect(ws1.layout == .tree && ws1.order.count == 2)
        let g = ws1.order.first { ws1.groups[$0] != nil }!
        #expect(ws1.groups[g]!.members == [WindowID("M"), WindowID("N")] && ws1.groups[g]!.active == WindowID("N"))
        #expect(e.home[WindowID("G")] == "2" && e.home[WindowID("S")] == "1")
        // same geometry as before the "reboot"
        #expect(e.sent[WindowID("S")] == old.sent[WindowID("s1")])
        #expect(e.sent[WindowID("N")] == old.sent[WindowID("n1")])
        // new groups don't collide with restored ids
        _ = e.handle(.command(.focusWindow(WindowID("S"))), now: 1)
        _ = e.handle(.command(.group(nil)), now: 2)
        #expect(e.workspaces["1"]!.groups.count == 2)
    }

    @Test func windowsTrickleInAndTheLayoutFillsUpWithoutHoles() {
        let (_, snap) = arranged()
        var e = engine()
        _ = e.handle([.restoreSession(snap, until: 60), .windowAdded(comeBack[0])], now: 0)   // only Safari so far
        #expect(e.restoring != nil)
        #expect(e.sent[WindowID("S")] == Rect(x: 0, y: 33, width: 1512, height: 894))       // no hole for Mail
        _ = e.handle([.windowAdded(comeBack[1]), .windowAdded(comeBack[2])], now: 10)
        #expect(e.sent[WindowID("S")]!.width < 1512)                                         // Mail's group took its slot
        _ = e.handle(.windowAdded(comeBack[3]), now: 20)
        #expect(e.restoring == nil && e.home[WindowID("G")] == "2")
    }

    @Test func graceDeadlineEndsTheRestore() {
        let (_, snap) = arranged()
        var e = engine()
        _ = e.handle([.restoreSession(snap, until: 60), .windowAdded(comeBack[0])], now: 0)
        _ = e.handle(.windowFocused(WindowID("S")), now: 61)
        #expect(e.restoring == nil)
        _ = e.handle(.windowAdded(comeBack[3]), now: 70)                                      // Ghostty late
        #expect(e.home[WindowID("G")] == e.active)                                           // normal new window
    }

    @Test func userCommandStopsTheRestore() {
        let (_, snap) = arranged()
        var e = engine()
        _ = e.handle([.restoreSession(snap, until: 60), .windowAdded(comeBack[0])], now: 0)
        let fx = e.handle(.command(.layout(.monocle)), now: 1)
        #expect(e.restoring == nil && e.activeWorkspace.layout == .monocle)
        #expect(fx.contains(.log("session restore stopped — you took over")))
        // the palette doesn't count as taking over
        var f = engine()
        _ = f.handle([.restoreSession(snap, until: 60), .windowAdded(comeBack[0])], now: 0)
        _ = f.handle(.command(.palette), now: 1)
        #expect(f.restoring != nil)
    }

    @Test func extraWindowsGoWhereTheirAppWas() {
        let (_, snap) = arranged()
        var e = engine()
        let second = win("G2", app: "Ghostty", title: "htop", x: 700)
        _ = e.handle([.restoreSession(snap, until: 60)] + (comeBack + [second]).map(Event.windowAdded), now: 0)
        #expect(e.home[WindowID("G2")] == "2")                       // Ghostty lived on workspace 2
    }

    @Test func sameTitlesAreTellApartByOrderAndPosition() {
        var e = engine()
        _ = e.handle([.windowAdded(win("t1", app: "Terminal", title: "zsh", x: 0)),
                      .windowAdded(win("t2", app: "Terminal", title: "zsh", x: 800))], now: 0)
        _ = e.handle(.command(.focusWindow(WindowID("t1"))), now: 1)
        _ = e.handle(.command(.moveToWorkspace("3", follow: false)), now: 2)
        let snap = e.snapshot(savedAt: 0)!
        let match = SessionMatcher.match(windows: [win("A", app: "Terminal", title: "zsh", x: 0), win("B", app: "Terminal", title: "zsh", x: 800)],
                                         slots: snap.windows)
        #expect(match[WindowID("A")] == WindowID("t1") && match[WindowID("B")] == WindowID("t2"))
    }

    @Test func noSnapshotWhileRestoringAndTitlesCanStayOffDisk() {
        let (_, snap) = arranged()
        var e = engine()
        _ = e.handle([.restoreSession(snap, until: 60), .windowAdded(comeBack[0])], now: 0)
        #expect(e.snapshot(savedAt: 0) == nil)

        var s = Settings(gaps: noGaps)
        s.session.saveTitles = false
        var f = engine(s)
        _ = f.handle(.windowAdded(win("x", app: "Mail", title: "Secret project")), now: 0)
        #expect(f.snapshot(savedAt: 0)!.windows.allSatisfy { $0.title == nil })
    }

    @Test func missingDisplayFallsBackToTheMainOne() {
        // Saved on the dual setup, restored on the laptop alone.
        var d = Engine(settings: Settings(gaps: noGaps), displays: [mainD, extD])
        _ = d.handle(.windowAdded(win("s1", app: "Safari", title: "A")), now: 0)
        _ = d.handle(.command(.focusDisplay(.next)), now: 1)
        _ = d.handle(.windowAdded(win("g1", app: "Ghostty", title: "zsh")), now: 1)
        let snap = d.snapshot(savedAt: 0)!
        #expect(snap.visible == ["Built-in Retina Display": "1", "DELL U2720Q": "2"])
        var e = engine()                                            // laptop only
        _ = e.handle([.restoreSession(snap, until: 60), .windowAdded(win("S", app: "Safari", title: "A")),
                      .windowAdded(win("G", app: "Ghostty", title: "zsh"))], now: 0)
        #expect(e.restoring == nil && e.home[WindowID("G")] == "2" && e.active == "2")
        #expect(e.sent[WindowID("G")] == screen.visibleFrame)       // its workspace is shown on the laptop
    }

    @Test func titleSimilarity() {
        #expect(SessionMatcher.similarity("Inbox – Mail", "Inbox (2) – Mail") > 0.5)
        #expect(SessionMatcher.similarity("Apple", "Google") == 0)
        #expect(try! Command.parse("session save") == .session(.save))
    }
}
