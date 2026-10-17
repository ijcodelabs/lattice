import Testing
@testable import LatticeCore

/// Laptop (primary, 1512×982) with an external 2560×1440 to its right.
let mainD = Display(id: 1, name: "Built-in Retina Display", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: Rect(x: 0, y: 33, width: 1512, height: 894), isPrimary: true)
let extD = Display(id: 2, name: "DELL U2720Q", frame: Rect(x: 1512, y: 0, width: 2560, height: 1440),
                   visibleFrame: Rect(x: 1512, y: 25, width: 2560, height: 1415), isPrimary: false)

func dual(_ s: Settings = Settings(gaps: noGaps)) -> Engine { Engine(settings: s, displays: [mainD, extD]) }

@Suite struct MultiDisplayTests {
    @Test func eachDisplayShowsAWorkspace() {
        let e = dual()
        #expect(e.visible == [1: "1", 2: "2"])
        #expect(e.active == "1" && e.focusedDisplay.id == 1)
        #expect(e.visibleWorkspaces == ["1", "2"])
        #expect(e.bars.isEmpty)   // bar disabled in these settings
    }

    @Test func windowsTileOnTheirOwnDisplay() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.next)), now: 1)
        #expect(e.active == "2")
        let fx = frames(e.handle(.windowAdded(snap(b)), now: 2))
        #expect(fx[b] == extD.visibleFrame)               // b fills the external display
        #expect(e.sent[a] == mainD.visibleFrame)          // a still fills the laptop
        #expect(e.parked.isEmpty)                         // both workspaces are visible
    }

    @Test func focusAndMoveCrossDisplays() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.direction(.right))), now: 1)
        _ = e.handle(.windowAdded(snap(b)), now: 1)
        // focus left from the external display lands on the laptop's window
        let fx = e.handle(.command(.focus(.left)), now: 2)
        #expect(fx.contains(.focus(a)))
        #expect(e.active == "1")
        // move right carries a onto the external display, next to b
        _ = e.handle(.command(.move(.right)), now: 3)
        #expect(e.home[a] == "2" && e.workspaces["2"]!.order == [b, a] && e.active == "2")
        #expect(e.sent[a]!.minX >= extD.frame.minX)
        // moving further right at the edge does nothing (no display there)
        _ = e.handle(.command(.move(.right)), now: 4)
        #expect(e.home[a] == "2")
        // move-to-display left brings it back to the (now empty) laptop
        _ = e.handle(.command(.moveToDisplay(.direction(.left))), now: 5)
        #expect(e.home[a] == "1" && e.active == "1" && e.sent[a] == mainD.visibleFrame)
    }

    @Test func focusTowardsAnEmptyDisplayFocusesIt() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focus(.right)), now: 1)
        #expect(e.active == "2")
    }

    @Test func workspaceSwitchUsesTheRightDisplay() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.next)), now: 0)
        _ = e.handle(.windowAdded(snap(b)), now: 0)                       // b on "2" (external)
        _ = e.handle(.command(.focusDisplay(.next)), now: 0)               // back on the laptop
        // "2" (with a window) is visible on the external display → just focus it, nothing is parked
        _ = e.handle(.command(.workspace("2")), now: 1)
        #expect(e.visible == [1: "1", 2: "2"] && e.active == "2" && e.parked.isEmpty)
        // "3" (never shown) appears on the focused (external) display, replacing "2"
        _ = e.handle(.command(.workspace("3")), now: 2)
        _ = e.handle(.windowAdded(snap(c)), now: 2)                       // c on "3"
        #expect(e.visible == [1: "1", 2: "3"])
        // "1" is visible on the laptop → focus moves there; "3" stays on the external
        _ = e.handle(.command(.workspace("1")), now: 3)
        #expect(e.visible == [1: "1", 2: "3"] && e.active == "1")
        // "2" was last on the external display → it comes back there, not on the laptop
        _ = e.handle(.command(.workspace("2")), now: 4)
        #expect(e.visible == [1: "1", 2: "2"])
    }

    @Test func pinnedWorkspacesGoToTheirDisplay() {
        var s = Settings(gaps: noGaps)
        s.workspaceDisplays = ["9": .name("dell"), "1": .main]
        var e = dual(s)
        #expect(e.assigned["9"] == 2)
        _ = e.handle(.command(.workspace("9")), now: 1)     // focused = laptop, but 9 is pinned to DELL
        #expect(e.visible == [1: "1", 2: "9"] && e.active == "9")
    }

    @Test func unplugMovesEverythingToMainAndReplugRestores() {
        var s = Settings(gaps: noGaps)
        s.workspaceDisplays = ["2": .secondary]
        var e = dual(s)
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.next)), now: 1)
        _ = e.handle(.windowAdded(snap(b)), now: 1)
        let onExt = e.sent[b]!

        // unplug: workspace 2 (focused) moves to the laptop and stays focused; 1 is hidden + parked
        let fx = e.handle(.displaysChanged([mainD]), now: 2)
        #expect(e.visible == [1: "2"] && e.active == "2")
        #expect(frames(fx)[b] == mainD.visibleFrame)
        #expect(e.parked[a] != nil)
        #expect(Rescue.isStranded(e.sent[a]!, displays: [mainD]))   // parked on the laptop, not on the ghost display

        // re-plug: the pin sends 2 back to the external display; the laptop shows 1 again
        _ = e.handle(.displaysChanged([mainD, extD]), now: 3)
        #expect(e.visible == [1: "1", 2: "2"])
        #expect(e.sent[b] == onExt && e.sent[a] == mainD.visibleFrame && e.parked.isEmpty)
    }

    @Test func moveWorkspaceToDisplayRefillsTheSource() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.moveWorkspaceToDisplay(.next)), now: 1)
        #expect(e.visible[2] == "1" && e.active == "1")
        #expect(e.visible[1] != nil && e.visible[1] != "1")        // laptop shows another workspace
        #expect(e.sent[a]!.minX >= extD.frame.minX)
    }

    @Test func clickingIntoTheOtherDisplayFocusesItsWorkspace() {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.focusDisplay(.next)), now: 0)
        _ = e.handle(.windowAdded(snap(b)), now: 0)
        _ = e.handle(.windowFocused(a), now: 0.1)      // immediately: not an echo case, a is visible
        #expect(e.active == "1" && e.parked.isEmpty)
    }

    @Test func barsAndStateKnowTheirDisplays() {
        var e = dual()
        var s = e.settings
        s.bar = BarSettings(enabled: true, height: 30)
        _ = e.handle(.settingsChanged(s), now: 0)
        #expect(e.bars.map(\.frame) == [Rect(x: 0, y: 33, width: 1512, height: 30), Rect(x: 1512, y: 25, width: 2560, height: 30)])
        let st = BarState.from(e, mode: nil)
        #expect(st.workspaces.first { $0.name == "2" } == .init(name: "2", active: false, windows: 0, display: 2, visible: true))
    }

    @Test func selectorsAndTargets() throws {
        let ds = [extD, mainD]
        #expect(DisplaySelector.parse("main").resolve(in: ds)?.id == 1)
        #expect(DisplaySelector.parse("secondary").resolve(in: ds)?.id == 2)
        #expect(DisplaySelector.parse("2").resolve(in: ds)?.id == 2)      // left → right
        #expect(DisplaySelector.parse("Dell").resolve(in: ds)?.id == 2)
        #expect(DisplaySelector.parse("LG").resolve(in: ds) == nil)
        #expect(DisplayTarget.direction(.right).resolve(from: mainD, in: ds)?.id == 2)
        #expect(DisplayTarget.direction(.left).resolve(from: mainD, in: ds) == nil)
        #expect(DisplayTarget.next.resolve(from: extD, in: ds)?.id == 1)
        #expect(DisplayTarget.next.resolve(from: mainD, in: [mainD]) == nil)
        #expect(try Command.parse("focus-display next") == .focusDisplay(.next))
        #expect(try Command.parse("move-workspace-to-display left") == .moveWorkspaceToDisplay(.direction(.left)))
    }

    @Test func floatingWindowsKeepTheirRelativeSpotAcrossDisplays() {
        let r = Engine.translate(Rect(x: 756, y: 480, width: 400, height: 300), from: mainD, to: extD)
        #expect(r.minX > extD.visibleFrame.center.x - 10 && r.minX < extD.visibleFrame.center.x + 10)
        #expect(r.maxX <= extD.visibleFrame.maxX && r.width == 400)
    }
}
