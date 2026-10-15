import Testing
@testable import LatticeCore

@Suite struct EquivalentTreeTests {
    let areas = [Rect(x: 0, y: 30, width: 3440, height: 1410),      // ultrawide
                 Rect(x: 0, y: 33, width: 1512, height: 894),       // laptop
                 Rect(x: 0, y: 0, width: 800, height: 1600)]        // portrait
    let gapsSets = [Gaps(inner: 0, outer: 0), Gaps(inner: 8, outer: 8), Gaps(inner: 12, outer: 4)]

    func same(_ x: [WindowID: Rect], _ y: [WindowID: Rect]) -> Bool {
        x.count == y.count && x.allSatisfy { k, r in y[k].map { r.approximatelyEquals($0, tolerance: 0.5) } ?? false }
    }

    @Test func dwindleAndMasterConvertWithoutMovingAnything() {
        for kind in [LayoutKind.dwindle, .master] {
            for n in 1...6 {
                let order = (0..<n).map { WindowID("w\($0)") }
                for area in areas {
                    for gaps in gapsSets {
                        for ratio in [0.5, 0.47, 0.62] {
                            let before = Layout.frames(kind: kind, tree: LayoutTree(), order: order, focused: nil, area: area, ratio: ratio, gaps: gaps)
                            let tree = Layout.equivalentTree(kind: kind, order: order, area: area, ratio: ratio, gaps: gaps)
                            let after = Layout.frames(kind: .tree, tree: tree, order: order, focused: nil, area: area, ratio: ratio, gaps: gaps)
                            #expect(same(before, after), "\(kind) n=\(n) area=\(area) gaps=\(gaps) ratio=\(ratio)")
                        }
                    }
                }
            }
        }
    }

    /// The user's real layout: dwindle [Ghostty group, Claude, Zen group] on the ultrawide.
    @Test func userCaseNewTerminalGoesBelowTheGhosttyGroup() {
        let uw = Display(id: 2, name: "ROG PG348Q", frame: Rect(x: 0, y: 0, width: 3440, height: 1440),
                         visibleFrame: Rect(x: 0, y: 30, width: 3440, height: 1410), isPrimary: true)
        var e = Engine(settings: Settings(gaps: Gaps(inner: 8, outer: 8)), displays: [uw])
        let g1 = WindowID("ghostty1"), g2 = WindowID("ghostty2"), claude = WindowID("claude"), z1 = WindowID("zen1"), z2 = WindowID("zen2")
        _ = e.handle([.windowAdded(snap(g1)), .windowAdded(snap(g2)), .windowAdded(snap(claude)),
                      .windowAdded(snap(z1)), .windowAdded(snap(z2))], now: 0)
        _ = e.handle(.command(.focusWindow(g2)), now: 1)
        _ = e.handle(.command(.group(.left)), now: 1)                 // ghostty group (left)
        _ = e.handle(.command(.focusWindow(z2)), now: 2)
        _ = e.handle(.command(.group(.up)), now: 2)                   // zen group
        _ = e.handle(.command(.focusWindow(g2)), now: 3)
        let groupBefore = e.sent[g2]!, claudeBefore = e.sent[claude]!

        let split = e.handle(.command(.split(.vertical)), now: 4)
        #expect(e.activeWorkspace.layout == .tree)
        #expect(frames(split).isEmpty)                                 // converting moved nothing

        let fx = e.handle(.windowAdded(snap(WindowID("ghostty3"))), now: 5)
        let f = frames(fx), new = f[WindowID("ghostty3")]!
        #expect(abs(new.minX - groupBefore.minX) < 1 && abs(new.width - groupBefore.width) < 1)   // same column
        #expect(new.minY > f[g2]!.maxY - 1)                                                       // below the group
        #expect(f[claude] == nil || f[claude] == claudeBefore)                                    // Claude untouched
        #expect(e.workspaces["1"]!.groups.count == 2)                                            // groups intact
    }

    @Test func splitInDwindleWorksForPlainWindowsToo() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)      // a | b, b focused
        _ = e.handle(.command(.split(.vertical)), now: 1)
        let fx = e.handle(.windowAdded(snap(c)), now: 2)
        let f = frames(fx)
        #expect(abs(f[c]!.minX - 756) < 1 && f[c]!.minY > f[b]!.maxY - 1)          // c under b, a unchanged
        #expect(f[a] == nil)
    }
}
