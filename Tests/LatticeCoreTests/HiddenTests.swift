import Testing
@testable import LatticeCore

/// Real observations from `park-test --app Zen` on 2026-10-14 (1512×982 laptop display).
@Suite struct HiddenTests {
    let displays = [laptop]
    let size = Size(width: 1512, height: 894)

    @Test func observedOffscreenClampIsVisible() {
        // Requested (1512,982); macOS/app pulled it back to (1472,895): a 40×87 chunk stays visible.
        let observed = Rect(origin: Point(x: 1472, y: 895), size: size)
        #expect(observed.largestVisiblePiece(on: displays) == Rect(x: 1472, y: 895, width: 40, height: 87))
        #expect(!Parking.isEffectivelyHidden(observed, displays: displays))
    }

    @Test func observedSliverClampIsHidden() {
        // Requested (1511,981); y clamped to 895 but x honoured: a 1×87 strip — effectively hidden.
        let observed = Rect(origin: Point(x: 1511, y: 895), size: size)
        #expect(Parking.isEffectivelyHidden(observed, displays: displays))
    }

    @Test func fullyOffscreenIsHidden() {
        #expect(Parking.isEffectivelyHidden(Rect(origin: Point(x: 1600, y: 0), size: size), displays: displays))
        #expect(laptop.frame.largestVisiblePiece(on: []) == nil)
    }

    @Test func defaultStrategyIsSliverBottomRight() throws {
        let plan = try #require(Parking.plan(size: size, home: laptop, displays: displays))
        #expect(plan.strategy == .sliver)
        #expect(plan.corner == .bottomRight)
    }

    @Test func shortNeighbourCatchesClampedWindow() throws {
        // External monitor to the right, top-aligned but only 900pt tall: the *requested* bottom-right frame
        // (y ≥ 981) misses it, but macOS clamps y up to ~895 and the window would show on it. Must pick left.
        let short = Display(id: 3, name: "Short", frame: Rect(x: 1512, y: 0, width: 1600, height: 900),
                            visibleFrame: Rect(x: 1512, y: 25, width: 1600, height: 875), isPrimary: false)
        let requested = Parking.parkedFrame(size: size, display: laptop.frame, corner: .bottomRight, strategy: .sliver)
        #expect(!requested.intersects(short.frame))
        let clamped = Rect(origin: Point(x: 1511, y: 895), size: size) // what macOS actually does (Zen run)
        #expect(clamped.intersects(short.frame))

        let plan = try #require(Parking.plan(size: size, home: laptop, displays: [laptop, short]))
        #expect(plan.corner == .bottomLeft)
    }

    @Test func forcedCornerIsRespected() throws {
        let plan = try #require(Parking.plan(size: size, home: laptop, displays: displays, strategy: .sliver, corners: [.topLeft]))
        #expect(plan.corner == .topLeft)
        #expect(plan.frame.maxX == 1 && plan.frame.maxY == 1)
    }
}
