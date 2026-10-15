import Testing
@testable import LatticeCore

/// The user's real setup (2026-10-15): ultrawide on top as main, laptop below it, offset to the right.
let ultra = Display(id: 2, name: "ROG PG348Q", frame: Rect(x: 0, y: 0, width: 3440, height: 1440),
                    visibleFrame: Rect(x: 0, y: 30, width: 3440, height: 1410), isPrimary: true)
let laptopBelow = Display(id: 1, name: "Built-in Retina Display", frame: Rect(x: 980, y: 1440, width: 1512, height: 982),
                          visibleFrame: Rect(x: 980, y: 1470, width: 1512, height: 894), isPrimary: false)

@Suite struct FocusWrapTests {
    /// Three windows on the ultrawide (dwindle: a | b | c across the width), c focused.
    func setup(_ s: Settings = Settings(gaps: noGaps)) -> Engine {
        var e = Engine(settings: s, displays: [ultra, laptopBelow])
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        return e
    }

    func rightmost(_ e: Engine) -> WindowID { e.visibleFrames().max { $0.value.maxX < $1.value.maxX }!.key }
    func leftmost(_ e: Engine) -> WindowID { e.visibleFrames().min { $0.value.minX < $1.value.minX }!.key }

    @Test func laptopBelowIsNotLeftOrRight() {
        #expect(DisplayTarget.direction(.right).resolve(from: ultra, in: [ultra, laptopBelow]) == nil)
        #expect(DisplayTarget.direction(.left).resolve(from: ultra, in: [ultra, laptopBelow]) == nil)
        #expect(DisplayTarget.direction(.down).resolve(from: ultra, in: [ultra, laptopBelow])?.id == 1)
        #expect(DisplayTarget.direction(.up).resolve(from: laptopBelow, in: [ultra, laptopBelow])?.id == 2)
    }

    @Test func focusRightAtTheLastWindowWrapsInsteadOfGettingStuck() {
        var e = setup()
        let r = rightmost(e), l = leftmost(e)
        _ = e.handle(.command(.focusWindow(r)), now: 1)
        let fx = e.handle(.command(.focus(.right)), now: 2)
        #expect(e.active == "1")                       // the bug: this jumped to the laptop's empty workspace
        #expect(fx.contains(.focus(l)) && e.focused == l)
        let back = e.handle(.command(.focus(.left)), now: 3)   // and left from the leftmost wraps to the rightmost
        #expect(back.contains(.focus(r)))
    }

    @Test func focusDownReachesTheLaptopAndUpComesBack() {
        var e = setup()
        _ = e.handle(.command(.focus(.down)), now: 1)
        #expect(e.active == "2" && e.focused == nil)        // laptop's workspace (empty)
        _ = e.handle(.command(.focus(.right)), now: 2)      // empty, nothing to the right: harmless
        #expect(e.active == "2")
        let fx = e.handle(.command(.focus(.up)), now: 3)    // never a dead end
        #expect(e.active == "1" && !fx.isEmpty)
    }

    @Test func moveSidewaysAtTheEdgeStaysMoveDownGoesToTheLaptop() {
        var e = setup()
        let r = rightmost(e)
        _ = e.handle(.command(.focusWindow(r)), now: 1)
        _ = e.handle(.command(.move(.right)), now: 2)
        #expect(e.home[r] == "1")                           // no display to the right: stays
        _ = e.handle(.command(.move(.down)), now: 3)
        #expect(e.home[r] == "2" && e.sent[r] == laptopBelow.visibleFrame)
    }

    @Test func wrapCanBeTurnedOff() {
        var s = Settings(gaps: noGaps)
        s.focusWrap = false
        var e = setup(s)
        let r = rightmost(e)
        _ = e.handle(.command(.focusWindow(r)), now: 1)
        #expect(e.handle(.command(.focus(.right)), now: 2).isEmpty && e.focused == r)
    }

    @Test func wrapPrefersWindowsLevelWithTheFocusedOne() {
        // a | (b over c): right from c wraps to a (level with c); down from c wraps to the top of its column (b).
        let frames = [a: Rect(x: 0, y: 0, width: 500, height: 600),
                      b: Rect(x: 500, y: 0, width: 500, height: 300),
                      c: Rect(x: 500, y: 300, width: 500, height: 300)]
        #expect(Layout.wrapTarget(from: c, .right, in: frames) == a)
        #expect(Layout.wrapTarget(from: c, .down, in: frames) == b)   // down from the bottom of the column → its top
        #expect(Layout.wrapTarget(from: a, .right, in: [a: frames[a]!]) == nil)
    }
}
