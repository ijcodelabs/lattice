import Testing
@testable import LatticeCore

/// Empty workspaces belong to no display and are forgotten when left (i3/sway). User request 2026-10-16:
/// "moved all windows from w1 to w3 (other monitor); opening w1 again should open it where I am".
@Suite struct EmptyWorkspaceTests {
    @Test func anEmptyWorkspaceShownElsewhereOpensWhereYouAre() {
        var e = dual()                                                    // laptop 1, external 2
        _ = e.handle(.windowAdded(snap(a)), now: 0)                       // a on 1 (laptop)
        _ = e.handle(.command(.moveToWorkspace("2", follow: false)), now: 1)   // 1 is now empty, still shown
        _ = e.handle(.command(.focusDisplay(.next)), now: 2)              // working on the external
        _ = e.handle(.command(.workspace("1")), now: 3)
        #expect(e.active == "1" && e.visible[extD.id] == "1")             // here, not on the laptop
        #expect(e.visible[mainD.id] != nil && e.visible[mainD.id] != "1") // the laptop shows another one
        #expect(e.home[a] == "2")
    }

    @Test func aWorkspaceLeftEmptyForgetsItsDisplayAndLayout() {
        var e = dual()
        _ = e.handle(.command(.workspace("4")), now: 1)                   // 4 opens on the laptop, empty
        _ = e.handle(.command(.layout(.master)), now: 2)
        _ = e.handle(.command(.workspace("1")), now: 3)                   // left empty → deleted
        #expect(e.assigned["4"] == nil && e.workspaces["4"]?.layout != .master)   // forgotten (listed names stay, fresh)
        _ = e.handle(.command(.focusDisplay(.next)), now: 4)
        _ = e.handle(.command(.workspace("4")), now: 5)
        #expect(e.visible[extD.id] == "4" && e.workspaces["4"]!.layout == Settings().defaultLayout)
    }

    @Test func unlistedWorkspacesAreRemoved() {
        var s = Settings(gaps: noGaps); s.workspaces = ["1", "2"]
        var e = dual(s)
        _ = e.handle(.command(.workspace("web")), now: 1)
        _ = e.handle(.command(.workspace("1")), now: 2)
        #expect(e.workspaces["web"] == nil && e.assigned["web"] == nil)
    }

    @Test func configuredWorkspacesStayListedButFresh() {
        var s = Settings(gaps: noGaps); s.workspaces = ["1", "2", "3"]
        var e = dual(s)
        _ = e.handle(.command(.workspace("3")), now: 1)
        _ = e.handle(.command(.layout(.monocle)), now: 2)
        _ = e.handle(.command(.workspace("1")), now: 3)
        #expect(e.workspaces["3"] != nil && e.workspaces["3"]!.layout == s.defaultLayout && e.assigned["3"] == nil)
    }

    @Test func workspacesWithWindowsKeepTheirDisplay() {
        var e = dual()
        _ = e.handle(.command(.focusDisplay(.next)), now: 0)
        _ = e.handle(.command(.workspace("3")), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 1)                       // c on 3 (external)
        _ = e.handle(.command(.workspace("2")), now: 2)                   // 3 hidden, but not empty
        _ = e.handle(.command(.focusDisplay(.next)), now: 3)              // laptop
        _ = e.handle(.command(.workspace("3")), now: 4)
        #expect(e.visible[extD.id] == "3" && e.visible[mainD.id] == "1")  // it comes back on the external
    }

    @Test func pinnedEmptyWorkspacesStillGoToTheirPin() {
        var s = Settings(gaps: noGaps); s.workspaceDisplays = ["5": .name("DELL")]
        var e = dual(s)
        _ = e.handle(.command(.workspace("5")), now: 1)                   // from the laptop
        #expect(e.visible[extD.id] == "5")
    }
}
