import Testing
@testable import LatticeCore

/// Laptop display from the real runs: visible area 1512×894 at y=33.
let screen = Display(id: 1, name: "Built-in", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                     visibleFrame: Rect(x: 0, y: 33, width: 1512, height: 894), isPrimary: true)

func snap(_ id: WindowID, app: String = "App", title: String = "") -> WindowSnapshot {
    WindowSnapshot(id: id, pid: 1, app: app, bundleID: nil, title: title, frame: Rect(x: 100, y: 100, width: 600, height: 400))
}

func engine(_ s: Settings = Settings(gaps: noGaps)) -> Engine { Engine(settings: s, displays: [screen]) }

func frames(_ effects: [Effect]) -> [WindowID: Rect] {
    var out: [WindowID: Rect] = [:]
    for case let .setFrame(id, r) in effects { out[id] = r }
    return out
}

@Suite struct EngineTests {
    @Test func newWindowsTileAndDiffingIsQuiet() {
        var e = engine()
        let fx = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        let f = frames(fx)
        #expect(f[a] == Rect(x: 0, y: 33, width: 756, height: 894))
        #expect(f[b] == Rect(x: 756, y: 33, width: 756, height: 894))
        // Nothing changed → nothing re-sent.
        #expect(frames(e.handle(.command(.balance), now: 1)).isEmpty)
        #expect(e.focused == b)
    }

    @Test func workspaceSwitchParksAndRestores() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        let tiled = e.sent

        let fx = e.handle(.command(.workspace("2")), now: 1)
        let parked = frames(fx)
        #expect(parked.count == 2)
        for (_, r) in parked { #expect(Parking.isEffectivelyHidden(r, displays: [screen]) || r.minX >= 1511) }
        #expect(e.parked == tiled)                          // journal = last on-screen frames
        #expect(!fx.contains { if case .focus = $0 { true } else { false } }) // empty workspace: nothing to focus

        let back = e.handle(.command(.workspaceBackAndForth), now: 2)
        #expect(frames(back) == tiled)
        #expect(e.parked.isEmpty)
        #expect(back.last == .focus(b))
    }

    @Test func osFocusOnHiddenWindowFollowsItButEchoesAreIgnored() {
        var e = engine()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.workspace("2")), now: 10)
        _ = e.handle(.windowFocused(a), now: 10.1)          // echo of our own switch
        #expect(e.active == "2")
        _ = e.handle(.windowFocused(a), now: 12)            // user Cmd-Tabbed to it
        #expect(e.active == "1")
        #expect(e.parked.isEmpty)
    }

    @Test func moveToWorkspaceKeepsTrackingAndRefocuses() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        let fx = e.handle(.command(.moveToWorkspace("3", follow: false)), now: 1)
        #expect(e.home[b] == "3" && e.windows[b] != nil)
        #expect(e.workspaces["1"]!.order == [a])
        #expect(frames(fx)[a] == Rect(x: 0, y: 33, width: 1512, height: 894))   // a now fills the screen
        #expect(fx.contains(.focus(a)))
        #expect(e.parked[b] != nil)

        _ = e.handle(.command(.moveToWorkspace("1", follow: true)), now: 2) // nothing focused on 1? a is → move a to 1 is a no-op
        _ = e.handle(.command(.workspace("3")), now: 3)
        _ = e.handle(.command(.moveToWorkspace("1", follow: true)), now: 4)
        #expect(e.active == "1" && e.workspaces["1"]!.order.count == 2 && e.focused == b)
    }

    @Test func focusAndMoveAreGeometric() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        // dwindle: a | (b over c); focus is c
        #expect(e.handle(.command(.focus(.up)), now: 1).contains(.focus(b)))
        #expect(e.handle(.command(.focus(.left)), now: 1).contains(.focus(a)))
        let fx = e.handle(.command(.move(.right)), now: 1)     // a swaps with its right neighbour
        #expect(e.workspaces["1"]!.order.first != a)
        #expect(frames(fx).count >= 2)
    }

    @Test func toggleFloatingAndLayoutSwitchAreLossless() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        _ = e.handle(.command(.toggleFloating), now: 1)       // c floats, centred
        #expect(e.workspaces["1"]!.floating[c] != nil && e.workspaces["1"]!.order == [a, b])
        _ = e.handle(.command(.layout(.tree)), now: 1)
        #expect(e.workspaces["1"]!.tree.leaves == [a, b])
        _ = e.handle(.command(.layout(.monocle)), now: 1)
        _ = e.handle(.command(.toggleFloating), now: 1)       // c back into tiling
        #expect(e.workspaces["1"]!.order == [a, b, c] && e.workspaces["1"]!.tree.leaves == [a, b, c])
    }

    @Test func closingFocusedWindowFocusesPrevious() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        let fx = e.handle(.windowRemoved(c), now: 1)
        #expect(fx.contains(.focus(b)) && e.windows[c] == nil && e.sent[c] == nil)
    }

    @Test func rulesFloatAndAssignWorkspace() {
        var s = Settings(gaps: noGaps)
        s.rules = [WindowRule(app: "^system settings$", float: true), WindowRule(app: "slack", workspace: "chat")]
        var e = engine(s)
        _ = e.handle([.windowAdded(snap(a, app: "System Settings")), .windowAdded(snap(b, app: "Slack"))], now: 0)
        #expect(e.workspaces["1"]!.floating[a] == Rect(x: 100, y: 100, width: 600, height: 400))
        #expect(e.home[b] == "chat" && e.parked[b] != nil)
    }

    @Test func resizeChangesRatioOrTreeWeights() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.focus(.left)), now: 0)
        let fx = e.handle(.command(.resize(grow: true, axis: nil, amount: 0.1)), now: 1)
        #expect(abs(frames(fx)[a]!.width - 1512 * 0.6) < 0.01)
        _ = e.handle(.command(.layout(.tree)), now: 1)
        let tfx = e.handle(.command(.resize(grow: true, axis: nil, amount: 0.1)), now: 1)
        #expect(abs(frames(tfx)[a]!.width - 1512 * 0.6) < 0.01)
    }

    @Test func restoreEffectsBringParkedWindowsBack() {
        var e = engine()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        let onScreen = e.sent[a]!
        _ = e.handle(.command(.workspace("2")), now: 1)
        #expect(e.restoreEffects() == [.setFrame(a, onScreen)])
    }

    @Test func floatingDragIsRememberedButOwnEchoIgnored() {
        var e = engine()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.command(.toggleFloating), now: 0)
        let own = e.sent[a]!
        _ = e.handle(.windowFrameObserved(a, own), now: 1)
        let dragged = Rect(x: 50, y: 60, width: 500, height: 400)
        _ = e.handle(.windowFrameObserved(a, dragged), now: 2)
        #expect(e.workspaces["1"]!.floating[a] == dragged)
    }
}

@Suite struct BarAndBorderTests {
    @Test func reservingBarShrinksTilingAreaOverlayDoesNot() {
        var s = Settings(gaps: noGaps)
        s.bar = BarSettings(enabled: true, position: .top, mode: .reserve, height: 30)
        var e = engine(s)
        let f = frames(e.handle(.windowAdded(snap(a)), now: 0))
        #expect(f[a] == Rect(x: 0, y: 63, width: 1512, height: 864))
        #expect(e.barFrame == Rect(x: 0, y: 33, width: 1512, height: 30))

        s.bar.position = .bottom
        _ = e.handle(.settingsChanged(s), now: 1)
        #expect(e.barFrame == Rect(x: 0, y: 897, width: 1512, height: 30))
        #expect(e.sent[a] == Rect(x: 0, y: 33, width: 1512, height: 864))

        s.bar.mode = .overlay
        _ = e.handle(.settingsChanged(s), now: 2)
        #expect(e.sent[a] == Rect(x: 0, y: 33, width: 1512, height: 894))
    }

    @Test func focusBorderFollowsObservedFrameAndHidesOffWorkspace() {
        var e = engine()
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        #expect(e.focusBorderFrame == e.sent[a])
        let clamped = Rect(x: 0, y: 33, width: 1000, height: 894)    // app refused the full width
        _ = e.handle(.windowFrameObserved(a, clamped), now: 1)
        #expect(e.focusBorderFrame == clamped)
        _ = e.handle(.command(.workspace("2")), now: 2)
        #expect(e.focusBorderFrame == nil)
        var off = Settings(gaps: noGaps); off.borders.enabled = false
        _ = e.handle([.settingsChanged(off), .command(.workspace("1"))], now: 3)
        #expect(e.focusBorderFrame == nil)
    }

    @Test func barStateListsWorkspacesAndFocus() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a, app: "Safari", title: "Apple")), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.moveToWorkspace("Mail", follow: false)), now: 1)
        let st = BarState.from(e, mode: "leader")
        #expect(st.workspaces.first == .init(name: "1", active: true, windows: 1, display: 1, visible: true))
        #expect(st.workspaces.last == .init(name: "Mail", active: false, windows: 1, display: 1, visible: false))
        #expect(st.focusedApp == "Safari" && st.focusedTitle == "Apple" && st.mode == "leader" && st.layout == .dwindle)
    }

    @Test func colorsParseAndPrint() {
        #expect(RGBA.parse("#88c0d0") == RGBA(r: 136 / 255, g: 192 / 255, b: 208 / 255))
        #expect(RGBA.parse("#fff")?.description == "#ffffff")
        #expect(RGBA.parse("#ff000080")!.a > 0.5 && RGBA.parse("#ff000080")!.a < 0.51)
        #expect(RGBA.parse("88c0d0") == nil && RGBA.parse("#12345") == nil && RGBA.parse("#gggggg") == nil)
    }
}
