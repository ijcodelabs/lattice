import Testing
@testable import LatticeCore

@Suite struct MouseDragTests {
    /// a | b (dwindle, no gaps, laptop area x 0…1512, y 33…927).
    func twoUp() -> Engine {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        return e
    }

    @Test func dropOntoAnotherWindowSwapsThem() {
        var e = twoUp()
        let leftFrame = e.sent[a]!, rightFrame = e.sent[b]!
        // a dragged into the middle of b and released there
        let fx = e.handle(.windowDragged(a, frame: Rect(x: 900, y: 200, width: 756, height: 894), cursor: Point(x: 1100, y: 300), float: false), now: 1)
        #expect(frames(fx)[a] == rightFrame && frames(fx)[b] == leftFrame)
    }

    @Test func dropOnEmptySpaceSnapsBack() {
        var e = engine()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        let home = e.sent[a]!
        // released over the menu bar (no window there): snap back
        let fx = e.handle(.windowDragged(a, frame: Rect(x: 300, y: 10, width: 1512, height: 894), cursor: Point(x: 600, y: 10), float: false), now: 1)
        #expect(frames(fx)[a] == home)
    }

    @Test func draggingTheSharedEdgeResizesTheSplit() {
        var e = twoUp()
        // a's right edge dragged 151pt right (≈ +10% of the width)
        let grown = Rect(x: 0, y: 33, width: 756 + 151.2, height: 894)
        let fx = e.handle(.windowDragged(a, frame: grown, cursor: Point(x: 907, y: 400), float: false), now: 1)
        #expect(abs(frames(fx)[a]!.width - 1512 * 0.6) < 1)
        #expect(abs(frames(fx)[b]!.minX - 1512 * 0.6) < 1)           // the neighbour followed
    }

    @Test func treeEdgeDragTakesSpaceFromTheSideThatMoved() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        _ = e.handle(.command(.layout(.tree)), now: 0)                // three equal columns of 504
        let mid = e.sent[b]!
        // b's LEFT edge dragged 100pt left: b grows, a (before) shrinks, c unchanged
        let fx = e.handle(.windowDragged(b, frame: Rect(x: mid.minX - 100, y: mid.minY, width: mid.width + 100, height: mid.height),
                                         cursor: Point(x: mid.minX - 100, y: 400), float: false), now: 1)
        let f = frames(fx)
        #expect(abs(f[a]!.width - 404) < 1 && abs(f[b]!.width - 604) < 1)
        #expect(f[c] == nil || abs(f[c]!.width - 504) < 1)
    }

    @Test func modifierDragFloatsWhereDropped() {
        var e = twoUp()
        let dropped = Rect(x: 200, y: 150, width: 500, height: 400)
        let fx = e.handle(.windowDragged(b, frame: dropped, cursor: Point(x: 300, y: 200), float: true), now: 1)
        #expect(e.workspaces["1"]!.floating[b] == dropped)
        #expect(frames(fx)[a] == Rect(x: 0, y: 33, width: 1512, height: 894))   // a now has the screen
    }

    @Test func floatingDragJustKeepsTheFrame() {
        var e = twoUp()
        _ = e.handle(.command(.toggleFloating), now: 1)
        let moved = Rect(x: 50, y: 60, width: 400, height: 300)
        _ = e.handle(.windowDragged(b, frame: moved, cursor: Point(x: 60, y: 70), float: false), now: 2)
        #expect(e.workspaces["1"]!.floating[b] == moved && e.sent[b] == moved)
    }

    @Test func dropOntoTheOtherDisplayMovesThere() {
        var e = Engine(settings: Settings(gaps: noGaps), displays: [mainD, extD])
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        let fx = e.handle(.windowDragged(a, frame: Rect(x: 2000, y: 300, width: 800, height: 600), cursor: Point(x: 2500, y: 500), float: false), now: 1)
        #expect(e.home[a] == "2" && e.active == "2" && frames(fx)[a] == extD.visibleFrame)
    }
}

@Suite struct HintTests {
    @Test func labelsAreHomeRowThenTwoLetters() {
        #expect(Hints.labels(count: 3) == ["a", "s", "d"])
        #expect(Hints.labels(count: 9).last == "h")
        let many = Hints.labels(count: 12)
        #expect(many.count == 12 && many.allSatisfy { $0.count == 2 } && Set(many).count == 12)
    }

    @Test func targetsAreInReadingOrderAcrossDisplays() {
        var e = Engine(settings: Settings(gaps: noGaps), displays: [mainD, extD])
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)        // laptop: a | b
        _ = e.handle(.command(.focusDisplay(.next)), now: 1)
        _ = e.handle(.windowAdded(snap(c)), now: 1)                                  // external: c
        #expect(e.hintTargets(excludingFocused: false).map(\.window) == [a, b, c])
        #expect(e.hintTargets(excludingFocused: true).map(\.window) == [a, b])       // c is focused
    }

    @Test func routerPicksByLabel() {
        let targets = [HintTarget(window: a, frame: Rect(x: 0, y: 0, width: 10, height: 10)),
                       HintTarget(window: b, frame: Rect(x: 20, y: 0, width: 10, height: 10))]
        var r = KeyRouter()
        r.startHints(.focus, targets)
        #expect(r.hint?.badges.map(\.label) == ["a", "s"])
        let res = r.handle(KeyChord(modifiers: [], key: "s"), settings: Settings(), now: 0)
        #expect(res.consumed && res.commands == [.focusWindow(b)] && r.hint == nil)
        // swap action
        r.startHints(.swap, targets)
        #expect(r.handle(KeyChord(modifiers: [], key: "a"), settings: Settings(), now: 0).commands == [.swapWindow(a)])
    }

    @Test func routerTwoLetterLabelsNarrowAndWrongKeysCancel() {
        let targets = (0..<12).map { HintTarget(window: WindowID("w\($0)"), frame: Rect(x: Double($0) * 10, y: 0, width: 5, height: 5)) }
        var r = KeyRouter()
        r.startHints(.focus, targets)
        let first = r.handle(KeyChord(modifiers: [], key: "a"), settings: Settings(), now: 0)
        #expect(first.consumed && first.commands.isEmpty && r.hint?.badges.allSatisfy { $0.label.hasPrefix("a") } == true)
        let second = r.handle(KeyChord(modifiers: [], key: "s"), settings: Settings(), now: 0)
        #expect(second.commands == [.focusWindow(WindowID("w1"))])
        // a key that matches no label cancels (and is swallowed)
        r.startHints(.focus, targets)
        let miss = r.handle(KeyChord(modifiers: [], key: "z"), settings: Settings(), now: 0)
        #expect(miss.consumed && r.hint == nil)
        r.startHints(.focus, targets)
        #expect(r.handle(KeyRouter.escape, settings: Settings(), now: 0).consumed && r.hint == nil)
    }

    @Test func hintsCommandEmitsTargets() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        let fx = e.handle(.command(.hints(.focus)), now: 1)
        #expect(fx.contains { if case let .startHints(.focus, t) = $0 { t.count == 2 } else { false } })
    }
}

@Suite struct SwapWindowTests {
    @Test func swapWithinAWorkspace() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)    // b focused, right
        let left = e.sent[a]!
        let fx = e.handle(.command(.swapWindow(a)), now: 1)
        #expect(frames(fx)[b] == left && e.focused == b && fx.contains(.focus(b)))
    }

    @Test func swapAcrossDisplays() {
        var e = Engine(settings: Settings(gaps: noGaps), displays: [mainD, extD])
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.next)), now: 1)
        _ = e.handle(.windowAdded(snap(b)), now: 1)                               // b on the external, focused
        _ = e.handle(.command(.swapWindow(a)), now: 2)
        #expect(e.home[b] == "1" && e.home[a] == "2" && e.focused == b && e.active == "1")
        #expect(e.sent[b] == mainD.visibleFrame && e.sent[a] == extD.visibleFrame)
    }

    @Test func swapWithAGroupedWindowTakesItsSlot() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.group(.left)), now: 1)                            // group [a, b], b shown
        _ = e.handle(.command(.focusWindow(a)), now: 2)                          // a shown
        _ = e.handle(.windowAdded(snap(c)), now: 3)                              // c joins → [a, c, b]
        _ = e.handle(.command(.ungroup), now: 4)                                 // c out, own tile
        _ = e.handle(.command(.swapWindow(b)), now: 5)                           // c ↔ b (b is a hidden member)
        let ws = e.workspaces["1"]!
        let g = ws.order.first { ws.groups[$0] != nil }!
        #expect(ws.groups[g]!.members.contains(c) && ws.order.contains(b))
    }

    @Test func parse() throws {
        #expect(try Command.parse("hints") == .hints(.focus))
        #expect(try Command.parse("hints swap") == .hints(.swap))
        #expect(try Command.parse("swap-window x:1") == .swapWindow(WindowID("x:1")))
        for t in ["hints", "hints swap"] { #expect(try Command.parse(t).description == t) }
    }
}
