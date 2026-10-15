import Testing
@testable import LatticeCore

/// Laptop visible area 1512×894 at y=33, no gaps, default tab strip (26pt, tabbed).
@Suite struct GroupTests {
    let full = Rect(x: 0, y: 33, width: 1512, height: 894)

    /// a | b side by side (dwindle, 2 windows), b focused.
    func twoUp() -> Engine {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        return e
    }

    @Test func groupWithNeighbourTakesItsTileAndParksTheOther() {
        var e = twoUp()
        let fx = e.handle(.command(.group(.left)), now: 1)     // b joins a's tile
        let ws = e.workspaces["1"]!
        #expect(ws.order.count == 1)
        let g = ws.order[0]
        #expect(ws.groups[g] == WindowGroup(members: [a, b], active: b, style: .tabbed))
        // the group fills the screen: strip on top, b below it, a parked
        #expect(e.sent[b] == Rect(x: 0, y: 59, width: 1512, height: 868))
        #expect(e.parked[a] != nil && Rescue.isStranded(e.sent[a]!, displays: [screen]))
        #expect(fx.contains(.focus(b)))
        #expect(e.groupStrips == [GroupStrip(id: g.raw, frame: Rect(x: 0, y: 33, width: 1512, height: 26), style: .tabbed,
                                            focused: true, tabs: [.init(window: "a", app: "App", title: "", active: false),
                                                                  .init(window: "b", app: "App", title: "", active: true)])])
    }

    @Test func cyclingSwitchesTheShownMemberAndIgnoresTheEcho() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        let fx = e.handle(.command(.groupCycle(1)), now: 10)
        #expect(fx.contains(.focus(a)) && e.focused == a)
        #expect(e.sent[a] == Rect(x: 0, y: 59, width: 1512, height: 868) && e.parked[b] != nil)
        _ = e.handle(.windowFocused(b), now: 10.1)              // echo of b being parked
        #expect(e.focused == a)
        _ = e.handle(.windowFocused(b), now: 12)                // user Cmd-Tabbed to b
        #expect(e.focused == b && e.parked[a] != nil && e.parked[b] == nil)
    }

    @Test func newWindowFromAGroupJoinsIt() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 2)
        let ws = e.workspaces["1"]!
        #expect(ws.order.count == 1 && ws.groups[ws.order[0]]!.members == [a, b, c] && ws.focused == c)
    }

    @Test func closingMembersDissolvesAtOne() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 2)
        _ = e.handle(.windowRemoved(c), now: 3)                 // 3 → 2: still a group, b shown again
        #expect(e.workspaces["1"]!.groups.count == 1 && e.focused == b)
        let fx = e.handle(.windowRemoved(b), now: 4)            // 2 → 1: dissolves, a is a plain tile again
        #expect(e.workspaces["1"]!.groups.isEmpty && e.workspaces["1"]!.order == [a])
        #expect(e.focused == a && fx.contains(.focus(a)) && e.sent[a] == full && e.parked.isEmpty)
        #expect(e.groupStrips.isEmpty)
    }

    @Test func toggleWrapsAndDissolves() {
        var e = twoUp()
        _ = e.handle(.command(.group(nil)), now: 1)             // b alone in a group of one
        var ws = e.workspaces["1"]!
        #expect(ws.order.count == 2 && ws.groups.count == 1 && ws.groups[ws.order[1]]!.members == [b])
        _ = e.handle(.windowAdded(snap(c)), now: 2)             // opened from b → joins
        ws = e.workspaces["1"]!
        #expect(ws.groups[ws.order[1]]!.members == [b, c])
        _ = e.handle(.command(.group(nil)), now: 3)             // dissolve: a, b, c as tiles
        ws = e.workspaces["1"]!
        #expect(ws.groups.isEmpty && ws.order == [a, b, c] && ws.tree.leaves == [a, b, c])
    }

    @Test func ungroupPutsTheWindowBesideTheGroup() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 2)              // group [a, b, c], c shown
        _ = e.handle(.command(.ungroup), now: 3)
        let ws = e.workspaces["1"]!
        #expect(ws.order.count == 2 && ws.order[1] == c && ws.groups[ws.order[0]]!.members == [a, b])
        #expect(e.focused == c && e.sent[c]!.minX > 700)         // c got its own tile on the right
    }

    @Test func groupsWorkInEveryLayout() {
        for kind in LayoutKind.allCases {
            var e = engine()
            _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
            _ = e.handle(.command(.layout(kind)), now: 0)
            _ = e.handle(.command(.focusWindow(c)), now: 0)
            _ = e.handle(.command(.group(kind == .monocle ? nil : .left)), now: 1)
            let ws = e.workspaces["1"]!
            #expect(ws.groups.count == 1, "layout \(kind)")
            // every window is either on screen or parked — never lost
            let onScreen = Set(e.visibleFrames().keys)
            for w in [a, b, c] { #expect(onScreen.contains(w) || e.parked[w] != nil, "layout \(kind): \(w) lost") }
            #expect(e.visibleFrames().count == ws.order.count, "layout \(kind): one window per tile on screen")
        }
    }

    @Test func swappingAGroupMovesTheWholeTile() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        // dwindle: a | (b over c) — group c into b (up), then move the group left
        _ = e.handle(.command(.group(.up)), now: 1)
        let g = e.workspaces["1"]!.order[1]
        _ = e.handle(.command(.move(.left)), now: 2)
        #expect(e.workspaces["1"]!.order == [g, a])
        #expect(e.sent[c]!.minX == 0)                             // the group's shown member is now on the left
    }

    @Test func movingAGroupedWindowAwayTakesOnlyThatWindow() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 2)              // [a, b, c]
        _ = e.handle(.command(.moveToWorkspace("2", follow: false)), now: 3)
        #expect(e.home[c] == "2")
        let ws = e.workspaces["1"]!
        #expect(ws.groups[ws.order[0]]!.members == [a, b] && e.focused == b)
    }

    @Test func floatingAGroupedWindowTakesItOut() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.command(.toggleFloating), now: 2)          // b floats → group of one left → dissolves
        let ws = e.workspaces["1"]!
        #expect(ws.floating[b] != nil && ws.groups.isEmpty && ws.order == [a])
        #expect(e.parked[a] == nil && e.sent[a] == full)
    }

    @Test func stackedStripGrowsWithMembersAndTabBarCanBeOff() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.command(.groupStyle(nil)), now: 2)          // tabbed → stacked
        #expect(e.groupStrips.first?.frame.height == 52 && e.sent[b]!.minY == 33 + 52)
        var s = e.settings
        s.groups.tabBar = false
        _ = e.handle(.settingsChanged(s), now: 3)
        #expect(e.groupStrips.isEmpty && e.sent[b] == full)
    }

    @Test func hiddenWorkspaceParksAllMembersAndRestoreBringsThemBack() {
        var e = twoUp()
        _ = e.handle(.command(.group(.left)), now: 1)
        let shown = e.sent[b]!
        _ = e.handle(.command(.workspace("2")), now: 2)
        #expect(e.parked[a] != nil && e.parked[b] == shown)
        #expect(Set(e.restoreEffects().compactMap { if case let .setFrame(id, _) = $0 { id } else { nil } }) == [a, b])
    }

    @Test func groupCommandsParse() throws {
        #expect(try Command.parse("group") == .group(nil))
        #expect(try Command.parse("group right") == .group(.right))
        #expect(try Command.parse("ungroup") == .ungroup)
        #expect(try Command.parse("group-next") == .groupCycle(1))
        #expect(try Command.parse("group-prev") == .groupCycle(-1))
        #expect(try Command.parse("group-style stacked") == .groupStyle(.stacked))
        #expect(try Command.parse("group-style toggle") == .groupStyle(nil))
        #expect(throws: Command.ParseError.self) { try Command.parse("group sideways") }
        for t in ["group", "group left", "ungroup", "group-next", "group-prev", "group-style tabbed", "group-style toggle"] {
            #expect(try Command.parse(t).description == t)
        }
    }
}
