import Foundation
import Testing
@testable import LatticeCore

/// macOS native tabs (user bug 2026-10-17, Ghostty cmd+t): the app lists only the selected tab's window.
/// A new tab must take its sibling's slot, not split the screen; hidden tabs must not leave blank slots.
@Suite struct NativeTabsTests {
    let pid: Int32 = 77
    func term(_ id: String, _ title: String, tabs: [String] = [], frame: Rect = Rect(x: 0, y: 0, width: 10, height: 10)) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(id), pid: pid, app: "Ghostty", bundleID: "com.mitchellh.ghostty", title: title,
                       frame: frame, tabs: tabs)
    }

    /// One Ghostty window tiled alone; then cmd+t.
    func oneWindow() -> (Engine, WindowSnapshot) {
        var e = engine()
        let m = term("77:1", "~")
        _ = e.handle(.windowAdded(m), now: 0)
        return (e, m)
    }

    func apply(_ e: inout Engine, _ w: WindowSnapshot, listed: Set<WindowID>) -> [Effect] {
        let events = NativeTabs.events(for: w, isKnown: e.windows[w.id] != nil, known: Array(e.windows.values),
                                       listed: listed, frames: e.sent)
        return e.handle(events, now: 1)
    }

    @Test func aNewTabTakesTheSlotInsteadOfSplitting() {
        var (e, m) = oneWindow()
        let full = e.sent[m.id]!
        let t = term("77:2", "~", tabs: ["~", "~"], frame: full)                  // cmd+t: new tab, same frame
        let fx = apply(&e, t, listed: [t.id])                                     // m is no longer listed
        #expect(e.workspaces["1"]!.order == [t.id] && e.windows[m.id] == nil)
        #expect(frames(fx)[t.id] == full && e.focused == t.id)
    }

    @Test func switchingTabsBackSwapsAgain() {
        var (e, m) = oneWindow()
        let full = e.sent[m.id]!
        let t = term("77:2", "build", tabs: ["~", "build"], frame: full)
        _ = apply(&e, t, listed: [t.id])
        let back = term("77:1", "~", tabs: ["~", "build"], frame: full)           // user selects the first tab
        _ = apply(&e, back, listed: [back.id])
        #expect(e.workspaces["1"]!.order == [m.id] && e.windows[t.id] == nil)
    }

    @Test func aHiddenTabLeftInTheLayoutIsCleanedUp() {
        var e = engine()
        let hidden = term("77:1", "./caffeinate.sh  ~"), shown = term("77:2", "~/P/G/A/store-assets")
        _ = e.handle([.windowAdded(hidden), .windowAdded(shown)], now: 0)       // the broken state: two tiles
        let withBar = term("77:2", "~/P/G/A/store-assets", tabs: ["./caffeinate.sh  ~", "~/P/G/A/store-assets"])
        _ = apply(&e, withBar, listed: [shown.id])
        #expect(e.workspaces["1"]!.order == [shown.id] && e.windows[hidden.id] == nil)
        #expect(e.sent[shown.id] == screen.visibleFrame)                          // the blank slot is gone
    }

    @Test func aSeparateWindowWithTheSameTitleIsNotATab() {
        var e = engine()
        let other = term("77:1", "~")
        _ = e.handle(.windowAdded(other), now: 0)
        let t = term("77:2", "~", tabs: ["~", "~"], frame: Rect(x: 500, y: 500, width: 10, height: 10))
        _ = apply(&e, t, listed: [other.id, t.id])                               // still listed → its own window
        #expect(e.workspaces["1"]!.order == [other.id, t.id])
    }

    @Test func withoutATabBarItIsJustANewWindow() {
        var (e, m) = oneWindow()
        let w = term("77:2", "~", frame: e.sent[m.id]!)
        #expect(NativeTabs.events(for: w, isKnown: false, known: Array(e.windows.values), listed: [w.id], frames: e.sent)
                == [.windowAdded(w)])
    }

    @Test func otherAppsAreNeverTabs() {
        var e = engine()
        let mine = WindowSnapshot(id: WindowID("9:1"), pid: 9, app: "Zen", bundleID: nil, title: "~", frame: screen.visibleFrame)
        _ = e.handle(.windowAdded(mine), now: 0)
        let t = term("77:2", "~", tabs: ["~", "x"], frame: screen.visibleFrame)
        #expect(NativeTabs.backgroundTabs(of: t, known: Array(e.windows.values), listed: [t.id], frames: e.sent).isEmpty)
    }

    @Test func aTabKeepsItsGroupAndFloatingPlace() {
        var e = engine()
        let m = term("77:1", "~"), n = WindowSnapshot(id: WindowID("9:1"), pid: 9, app: "Zen", bundleID: nil, title: "web",
                                                      frame: screen.visibleFrame)
        _ = e.handle([.windowAdded(n), .windowAdded(m)], now: 0)
        _ = e.handle(.command(.group(.left)), now: 1)                             // group [n, m], m shown
        let t = term("77:2", "~", tabs: ["~", "~"], frame: e.sent[m.id]!)
        _ = apply(&e, t, listed: [t.id])
        let ws = e.workspaces["1"]!
        let g = ws.groups.values.first!
        #expect(g.members.contains(t.id) && !g.members.contains(m.id) && g.active == t.id)
    }

    @Test func snapshotsWithoutTabsStillDecode() throws {
        let old = #"{"id":{"raw":"1:a"},"pid":1,"app":"A","title":"t","frame":{"origin":{"x":0,"y":0},"size":{"width":1,"height":1}}}"#
        let s = try JSONDecoder().decode(WindowSnapshot.self, from: Data(old.utf8))
        #expect(s.tabs.isEmpty)
    }

    // MARK: Closing a tab (cmd+w) while another one remains

    /// a | ghostty(2 tabs, shown "build") | b
    func threeTiles() -> (Engine, WindowSnapshot) {
        var e = engine()
        let shown = term("77:2", "build", tabs: ["~", "build"])
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(shown), .windowAdded(snap(b))], now: 0)
        return (e, shown)
    }

    @Test func theRemainingTabTakesTheClosedTabsSlot() {
        var (e, shown) = threeTiles()
        let order = e.workspaces["1"]!.order, slot = e.sent[shown.id]!
        _ = e.handle(.windowRemoved(shown.id), now: 10)                          // cmd+w on "build"
        #expect(e.workspaces["1"]!.order == order)                               // slot kept, nothing reflows
        let next = term("77:1", "~", frame: slot)                                 // the other tab shows (no tab bar now)
        _ = e.handle(.windowAdded(next), now: 10.3)
        #expect(e.workspaces["1"]!.order == [a, next.id, b] && e.windows[shown.id] == nil && e.sent[next.id] == slot)
        #expect(e.closedTabs.isEmpty)
    }

    @Test func matchedByTitleEvenIfItOpensElsewhere() {
        var (e, shown) = threeTiles()
        _ = e.handle(.windowRemoved(shown.id), now: 10)
        _ = e.handle(.windowAdded(term("77:1", "~", frame: Rect(x: 900, y: 900, width: 50, height: 50))), now: 10.5)
        #expect(e.workspaces["1"]!.order == [a, WindowID("77:1"), b])
    }

    @Test func nobodyComesTheSlotClosesAfterTheGrace() {
        var (e, shown) = threeTiles()
        _ = e.handle(.windowRemoved(shown.id), now: 10)
        _ = e.handle(.tick, now: 10 + Engine.closedTabGrace - 0.1)
        #expect(e.workspaces["1"]!.order.count == 3)
        _ = e.handle(.tick, now: 10 + Engine.closedTabGrace + 0.1)
        #expect(e.workspaces["1"]!.order == [a, b] && e.windows[shown.id] == nil && e.closedTabs.isEmpty)
    }

    @Test func aRepeatedRemovalDoesntGiveTheSlotUpEarly() {
        var (e, shown) = threeTiles()
        _ = e.handle(.windowRemoved(shown.id), now: 10)
        _ = e.handle(.windowRemoved(shown.id), now: 11)                          // reconcile reports it too
        _ = e.handle(.windowAdded(term("77:1", "~", frame: e.sent[shown.id]!)), now: 11.5)
        #expect(e.workspaces["1"]!.order == [a, WindowID("77:1"), b])
    }

    @Test func aWindowWithoutTabsClosesAsBefore() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(term("77:2", "x")), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.windowRemoved(WindowID("77:2")), now: 1)
        #expect(e.workspaces["1"]!.order == [a, b] && e.closedTabs.isEmpty)
    }

    @Test func anotherAppsWindowDoesntTakeTheSlot() {
        var (e, shown) = threeTiles()
        let slot = e.sent[shown.id]!
        _ = e.handle(.windowRemoved(shown.id), now: 10)
        let zen = WindowSnapshot(id: WindowID("9:9"), pid: 9, app: "Zen", bundleID: nil, title: "~", frame: slot)
        _ = e.handle(.windowAdded(zen), now: 10.2)
        #expect(e.workspaces["1"]!.order.contains(shown.id) && e.workspaces["1"]!.order.last == zen.id)
    }
}
