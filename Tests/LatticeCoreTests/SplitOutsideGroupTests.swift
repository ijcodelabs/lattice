import Testing
@testable import LatticeCore

@Suite struct SplitOutsideGroupTests {
    /// Group [a, b] (b shown) filling the screen.
    func grouped(_ layout: LayoutKind = .dwindle) -> (Engine, WindowID) {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.group(.left)), now: 1)
        _ = e.handle(.command(.layout(layout)), now: 1)
        return (e, e.workspaces["1"]!.order[0])
    }

    @Test func splitVerticalThenOpenGoesBelowTheGroupInTree() {
        var (e, g) = grouped(.tree)
        _ = e.handle(.command(.split(.vertical)), now: 2)
        let fx = e.handle(.windowAdded(snap(c)), now: 3)
        let ws = e.workspaces["1"]!
        #expect(ws.groups[g]!.members == [a, b] && ws.order.contains(c))
        let f = frames(fx)
        #expect(f[c]!.minY > e.sent[b]!.maxY - 1)                    // c below the group's shown window
        #expect(abs(f[c]!.width - 1512) < 1)                         // full width, under it
        #expect(ws.nextOutsideGroup == nil)                          // one-shot
    }

    @Test func splitHorizontalThenOpenGoesBeside() {
        var (e, _) = grouped(.tree)
        _ = e.handle(.command(.split(.horizontal)), now: 2)
        _ = e.handle(.windowAdded(snap(c)), now: 3)
        #expect(e.sent[c]!.minX > e.sent[b]!.maxX - 1)
    }

    @Test func withoutSplitTheNewWindowJoins() {
        var (e, g) = grouped(.tree)
        _ = e.handle(.windowAdded(snap(c)), now: 3)
        #expect(e.workspaces["1"]!.groups[g]!.members == [a, b, c])
    }

    @Test func worksInDwindleToo() {
        var (e, g) = grouped(.dwindle)
        _ = e.handle(.command(.split(.vertical)), now: 2)
        _ = e.handle(.windowAdded(snap(c)), now: 3)
        let ws = e.workspaces["1"]!
        #expect(ws.order == [g, c] && ws.groups[g]!.members == [a, b])
    }

    @Test func focusingElsewhereCancelsIt() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        _ = e.handle(.command(.group(.up)), now: 1)                  // c joins b (above) → group [b, c]
        _ = e.handle(.command(.split(.vertical)), now: 2)
        _ = e.handle(.command(.focus(.left)), now: 3)                // focus moves to a
        #expect(e.workspaces["1"]!.nextOutsideGroup == nil)
    }
}
