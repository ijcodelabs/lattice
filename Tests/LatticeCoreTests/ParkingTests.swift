import Testing
@testable import LatticeCore

/// Two displays side by side: primary 1512×982 (MacBook), external 2560×1440 to its right, top-aligned.
let laptop = Display(id: 1, name: "Built-in", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                     visibleFrame: Rect(x: 0, y: 33, width: 1512, height: 949), isPrimary: true)
let external = Display(id: 2, name: "External", frame: Rect(x: 1512, y: 0, width: 2560, height: 1440),
                       visibleFrame: Rect(x: 1512, y: 25, width: 2560, height: 1415), isPrimary: false)
let window = Size(width: 800, height: 600)

@Suite struct ParkingTests {
    @Test func singleDisplayParksBottomRight() throws {
        let plan = try #require(Parking.plan(size: window, home: laptop, displays: [laptop], strategy: .offscreen))
        #expect(plan.corner == .bottomRight)
        #expect(plan.frame.origin == Point(x: 1512, y: 982))
        #expect(plan.frame.visibleArea(on: [laptop]) == 0)
    }

    @Test func sliverLeavesOnePointVisible() throws {
        let plan = try #require(Parking.plan(size: window, home: laptop, displays: [laptop], strategy: .sliver))
        #expect(plan.frame.visibleArea(on: [laptop]) == 1)
    }

    @Test func neverParksOntoNeighbouringDisplay() throws {
        // Bottom-right of the laptop runs into the external display (it is taller), so pick another corner.
        let displays = [laptop, external]
        for strategy in ParkingStrategy.allCases {
            let plan = try #require(Parking.plan(size: window, home: laptop, displays: displays, strategy: strategy))
            #expect(plan.corner != .bottomRight)
            #expect(!plan.frame.intersects(external.frame))
        }
    }

    @Test func externalDisplayParksAwayFromLaptop() throws {
        let plan = try #require(Parking.plan(size: window, home: external, displays: [laptop, external], strategy: .offscreen))
        #expect(plan.corner == .bottomRight)
        #expect(!plan.frame.intersects(laptop.frame))
    }

    @Test func noSafeCornerReturnsNil() {
        // Home display boxed in by neighbours at every corner.
        let center = Display(id: 10, name: "C", frame: Rect(x: 1000, y: 1000, width: 1000, height: 1000),
                             visibleFrame: Rect(x: 1000, y: 1000, width: 1000, height: 1000), isPrimary: true)
        let ring = [
            Rect(x: 0, y: 0, width: 3000, height: 1000), Rect(x: 0, y: 2000, width: 3000, height: 1000),
            Rect(x: 0, y: 1000, width: 1000, height: 1000), Rect(x: 2000, y: 1000, width: 1000, height: 1000),
        ].enumerated().map { Display(id: UInt32(20 + $0), name: "R", frame: $1, visibleFrame: $1, isPrimary: false) }
        #expect(Parking.plan(size: window, home: center, displays: [center] + ring, strategy: .offscreen) == nil)
    }
}

@Suite struct ClassifierTests {
    let before = Rect(x: 100, y: 100, width: 800, height: 600)
    let requested = Rect(x: 1512, y: 982, width: 800, height: 600)

    @Test func honoredWhenOriginMatches() {
        #expect(FrameClassifier.classify(requested: requested, before: before, observed: requested) == .honored)
        // Size clamping alone doesn't matter for parking.
        let resized = Rect(x: 1513, y: 981, width: 500, height: 400)
        #expect(FrameClassifier.classify(requested: requested, before: before, observed: resized) == .honored)
    }

    @Test func clampedWhenPulledBack() {
        let pulled = Rect(x: 1412, y: 882, width: 800, height: 600)
        #expect(FrameClassifier.classify(requested: requested, before: before, observed: pulled) == .clamped)
    }

    @Test func ignoredAndFailed() {
        #expect(FrameClassifier.classify(requested: requested, before: before, observed: before) == .ignored)
        #expect(FrameClassifier.classify(requested: requested, before: before, observed: nil) == .failed)
    }
}
