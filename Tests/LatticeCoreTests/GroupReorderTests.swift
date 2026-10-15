import Testing
@testable import LatticeCore

@Suite struct GroupReorderTests {
    /// Group [a, b, c] with c shown and focused.
    func grouped() -> (Engine, WindowID) {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.group(.left)), now: 1)            // [a, b], b shown
        _ = e.handle(.windowAdded(snap(c)), now: 2)              // joins → [a, b, c], c shown
        return (e, e.workspaces["1"]!.order[0])
    }

    func members(_ e: Engine, _ g: WindowID) -> [WindowID] { e.workspaces["1"]!.groups[g]!.members }

    @Test func moveShiftsTheShownTabAndKeepsItShown() {
        var (e, g) = grouped()
        let shownFrame = e.sent[c]
        let fx = e.handle(.command(.groupMove(.left)), now: 3)
        #expect(members(e, g) == [a, c, b])
        #expect(e.focused == c && e.workspaces["1"]!.groups[g]!.active == c)
        #expect(e.sent[c] == shownFrame && frames(fx).isEmpty)      // nothing moves on screen, only the strip
        _ = e.handle(.command(.groupMove(.left)), now: 4)
        #expect(members(e, g) == [c, a, b])
        _ = e.handle(.command(.groupMove(.left)), now: 5)           // already first: stops
        #expect(members(e, g) == [c, a, b])
        _ = e.handle(.command(.groupMove(.down)), now: 6)           // down = later (stacked strips)
        #expect(members(e, g) == [a, c, b])
        #expect(e.groupStrips.first?.tabs.map(\.window) == ["a", "c", "b"])
    }

    @Test func moveAtTheEndStops() {
        var (e, g) = grouped()
        _ = e.handle(.command(.groupMove(.right)), now: 3)
        #expect(members(e, g) == [a, b, c])
    }

    @Test func tabNumberShowsThatTab() {
        var (e, g) = grouped()
        let fx = e.handle(.command(.groupTab(1)), now: 3)
        #expect(e.focused == a && e.workspaces["1"]!.groups[g]!.active == a && fx.contains(.focus(a)))
        #expect(e.parked[c] != nil && e.parked[a] == nil)
        _ = e.handle(.windowFocused(c), now: 3.1)                    // echo of c being parked
        #expect(e.focused == a)
        #expect(e.handle(.command(.groupTab(9)), now: 4).isEmpty)    // no tab 9: nothing
        #expect(e.handle(.command(.groupTab(1)), now: 5).isEmpty)    // already shown: nothing
    }

    @Test func noGroupNoEffect() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        let before = e.workspaces["1"]!
        #expect(e.handle(.command(.groupMove(.left)), now: 1).isEmpty)
        #expect(e.handle(.command(.groupTab(1)), now: 1).isEmpty)
        #expect(e.workspaces["1"]! == before)
    }

    @Test func parse() throws {
        #expect(try Command.parse("group-move left") == .groupMove(.left))
        #expect(try Command.parse("group-tab 3") == .groupTab(3))
        #expect(throws: Command.ParseError.self) { try Command.parse("group-tab 0") }
        #expect(throws: Command.ParseError.self) { try Command.parse("group-move sideways") }
        for t in ["group-move right", "group-tab 2"] { #expect(try Command.parse(t).description == t) }
    }
}
