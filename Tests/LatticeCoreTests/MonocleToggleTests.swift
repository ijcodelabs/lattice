import Foundation
import Testing
@testable import LatticeCore

/// mod+f (`layout monocle`) is a toggle: pressed again it goes back to the layout before it.
@Suite struct MonocleToggleTests {
    @Test func monocleAgainGoesBackWithTheSameFrames() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)       // dwindle: a | b
        let before = e.sent
        _ = e.handle(.command(.layout(.monocle)), now: 1)
        #expect(e.workspaces["1"]!.layout == .monocle && e.sent[b] == screen.visibleFrame)
        _ = e.handle(.command(.layout(.monocle)), now: 2)
        #expect(e.workspaces["1"]!.layout == .dwindle && e.sent[a] == before[a] && e.sent[b] == before[b])
    }

    @Test func aHandArrangedTreeSurvivesTheRoundTrip() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b)), .windowAdded(snap(c))], now: 0)
        _ = e.handle(.command(.layout(.tree)), now: 1)
        _ = e.handle(.command(.resize(grow: true, axis: nil, amount: 0.1)), now: 2)
        let arranged = e.sent
        _ = e.handle(.command(.layout(.monocle)), now: 3)
        _ = e.handle(.command(.layout(.monocle)), now: 4)
        #expect(e.workspaces["1"]!.layout == .tree && e.sent == arranged)
    }

    @Test func otherLayoutsDontToggle() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.layout(.master)), now: 1)
        _ = e.handle(.command(.layout(.master)), now: 2)
        #expect(e.workspaces["1"]!.layout == .master)
    }

    @Test func withNothingRememberedItFallsBackToTheDefaultLayout() {
        var s = Settings(gaps: noGaps); s.defaultLayout = .monocle
        var e = engine(s)
        _ = e.handle(.windowAdded(snap(a)), now: 0)                                // starts in monocle
        _ = e.handle(.command(.layout(.monocle)), now: 1)
        #expect(e.workspaces["1"]!.layout == .dwindle)                              // never stuck
    }

    @Test func previousLayoutIsSavedWithTheSession() throws {
        var ws = Workspace(name: "1", layout: .monocle, ratio: 0.5)
        ws.previousLayout = .tree
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(back.previousLayout == .tree)
        // sessions saved before this field existed still load
        let old = #"{"name":"1","layout":"dwindle","ratio":0.5,"order":[],"tree":{},"groups":{},"floating":{}}"#
        #expect((try? JSONDecoder().decode(Workspace.self, from: Data(old.utf8)))?.previousLayout == nil)
    }
}
