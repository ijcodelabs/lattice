import Foundation
import Testing
@testable import LatticeCore

func chord(_ s: String) -> KeyChord { try! KeyChord.parse(s, mod: [.ctrl, .alt]) }

/// mod+space → leader; leader: l → layout mode, f → toggle-floating, r → resize (sticky).
let routerSettings: Settings = {
    var s = Settings()
    s.bindings = [
        Binding(chord: chord("mod+space"), command: .mode("leader")),
        Binding(chord: chord("mod+1"), command: .workspace("1")),
    ]
    s.modes = [
        "leader": KeyMode(name: "leader", label: "Leader", bindings: [
            Binding(chord: chord("l"), command: .mode("layout"), label: "layouts"),
            Binding(chord: chord("f"), command: .toggleFloating, label: "float"),
            Binding(chord: chord("r"), command: .mode("resize")),
            Binding(chord: chord("x"), command: .mode("nonexistent")),
        ]),
        "layout": KeyMode(name: "layout", label: "Layout", bindings: [
            Binding(chord: chord("t"), command: .layout(.tree)),
        ]),
        "resize": KeyMode(name: "resize", label: "Resize", sticky: true, timeout: 0, bindings: [
            Binding(chord: chord("h"), command: .resize(grow: false, axis: .horizontal, amount: 0.05)),
            Binding(chord: chord("q"), command: .modeExit),
        ]),
    ]
    return s
}()

@Suite struct KeyRouterTests {
    @Test func unboundKeysPassThroughInNormalState() {
        var r = KeyRouter()
        let res = r.handle(chord("h"), settings: routerSettings, now: 0)
        #expect(!res.consumed && res.commands.isEmpty && r.mode == nil)
    }

    @Test func leaderThenSubModeThenCommandExits() {
        var r = KeyRouter()
        let v1 = r.handle(chord("mod+space"), settings: routerSettings, now: 0).modeChanged
        #expect(v1)
        #expect(r.mode == "leader")
        let v2 = r.handle(chord("l"), settings: routerSettings, now: 0.5).modeChanged
        #expect(v2)
        #expect(r.mode == "layout")
        let res = r.handle(chord("t"), settings: routerSettings, now: 1)
        #expect(res.consumed && res.commands == [.layout(.tree)] && r.mode == nil)
    }

    @Test func stickyModeStaysUntilEscapeOrExitCommand() {
        var r = KeyRouter()
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        _ = r.handle(chord("r"), settings: routerSettings, now: 0)
        for t in 1...3 {
            let res = r.handle(chord("h"), settings: routerSettings, now: Double(t))
            #expect(res.commands.count == 1 && r.mode == "resize")
        }
        let v3 = r.handle(chord("q"), settings: routerSettings, now: 4).modeChanged
        #expect(v3 && r.mode == nil)
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 5)
        _ = r.handle(chord("r"), settings: routerSettings, now: 5)
        let v4 = r.handle(KeyRouter.escape, settings: routerSettings, now: 6).consumed
        #expect(v4 && r.mode == nil)
    }

    @Test func unknownKeyInModeIsSwallowedAndExits() {
        var r = KeyRouter()
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        let res = r.handle(chord("z"), settings: routerSettings, now: 1)
        #expect(res.consumed && res.commands.isEmpty && r.mode == nil)
    }

    @Test func globalChordWorksFromInsideAMode() {
        var r = KeyRouter()
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        let res = r.handle(chord("mod+1"), settings: routerSettings, now: 1)
        #expect(res.commands == [.workspace("1")] && r.mode == nil && res.modeChanged)
    }

    @Test func timeoutExpiresNonStickyModes() {
        var r = KeyRouter()
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        let v5 = r.expire(settings: routerSettings, now: 3.9)
        #expect(!v5)
        let v6 = r.expire(settings: routerSettings, now: 4.1)
        #expect(v6 && r.mode == nil)
        // timeout 0 = never
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 10)
        _ = r.handle(chord("r"), settings: routerSettings, now: 10)
        let v7 = r.expire(settings: routerSettings, now: 1000)
        #expect(!v7)
    }

    @Test func missingModeIsIgnoredSafely() {
        var r = KeyRouter()
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        let res = r.handle(chord("x"), settings: routerSettings, now: 1)
        #expect(res.consumed && r.mode == "leader")
    }

    @Test func hudDescribesCurrentMode() throws {
        var r = KeyRouter()
        #expect(r.hud(settings: routerSettings) == nil)
        _ = r.handle(chord("mod+space"), settings: routerSettings, now: 0)
        let hud = try #require(r.hud(settings: routerSettings))
        #expect(hud.title == "Leader" && !hud.sticky)
        #expect(hud.items.first == HUDItem(key: "l", label: "layouts", isMode: true))
        #expect(hud.items.contains(HUDItem(key: "r", label: "Resize", isMode: true)))   // falls back to the mode's label
        #expect(hud.items.contains(HUDItem(key: "f", label: "float", isMode: false)))
    }
}

@Suite struct PaletteTests {
    @Test func fuzzyPrefersWordStartsAndRuns() throws {
        let ws = try #require(Fuzzy.score("ws", "Workspace Slack"))
        let mid = try #require(Fuzzy.score("ws", "news"))
        #expect(ws > mid)
        #expect(Fuzzy.score("xyz", "Safari") == nil)
        #expect(try #require(Fuzzy.score("saf", "Safari")) > (Fuzzy.score("saf", "Sales Forecast") ?? .min))
    }

    @Test func itemsCoverWindowsWorkspacesLayoutsCommands() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a, app: "Safari", title: "Apple")), .windowAdded(snap(b, app: "Ghostty"))], now: 0)
        _ = e.handle(.command(.moveToWorkspace("2", follow: false)), now: 1)
        let items = Palette.items(for: e)
        #expect(items.first?.kind == .window)
        #expect(items.contains { $0.title == "Safari — Apple" && $0.command == "focus-window a" })
        #expect(items.contains { $0.title == "Ghostty" && $0.subtitle == "workspace 2" })
        #expect(items.contains { $0.kind == .workspace && $0.title == "Workspace 1" && $0.subtitle == "current" })
        #expect(items.contains { $0.kind == .layout && $0.subtitle == "current" })
        #expect(items.contains { $0.command == "quit" })
        // Every command the palette emits must parse.
        for item in items { #expect((try? Command.parse(item.command)) != nil, "unparseable: \(item.command)") }

        let filtered = Palette.filter(items, query: "ghost")
        #expect(filtered.first?.title == "Ghostty")
        #expect(Palette.filter(items, query: "").count == items.count)
    }

    @Test func focusWindowSwitchesWorkspace() {
        var e = engine()
        _ = e.handle([.windowAdded(snap(a)), .windowAdded(snap(b))], now: 0)
        _ = e.handle(.command(.moveToWorkspace("2", follow: false)), now: 1)
        let fx = e.handle(.command(.focusWindow(b)), now: 2)
        #expect(e.active == "2" && fx.last == .focus(b))
    }

    @Test func protocolRoundTripsAsJSON() throws {
        let msgs: [UIRequest] = [
            .hud(HUDModel(title: "Leader", items: [HUDItem(key: "l", label: "layouts", isMode: true)], sticky: false)),
            .hud(nil), .openPalette([PaletteItem(id: "x", kind: .command, title: "T", subtitle: "s", command: "quit")]),
            .closePalette, .quit,
        ]
        for m in msgs {
            let data = try JSONEncoder().encode(m)
            #expect(try JSONDecoder().decode(UIRequest.self, from: data) == m)
        }
        let reply = UIReply.chose(id: "w:1:abc")
        #expect(try JSONDecoder().decode(UIReply.self, from: JSONEncoder().encode(reply)) == reply)
    }

    @Test func newCommandsParse() throws {
        #expect(try Command.parse("mode leader") == .mode("leader"))
        #expect(try Command.parse("mode-exit") == .modeExit)
        #expect(try Command.parse("palette") == .palette)
        #expect(try Command.parse("focus-window 12:ab") == .focusWindow(WindowID("12:ab")))
    }
}

@Suite struct HUDFoldTests {
    @Test func numberRunsFoldIntoOneRow() {
        let items = [HUDItem(key: "n", label: "next tab", isMode: false)]
            + (1...9).map { HUDItem(key: "\($0)", label: "tab \($0)", isMode: false) }
            + [HUDItem(key: "u", label: "take out", isMode: false)]
        #expect(KeyRouter.foldNumberRuns(items) == [
            HUDItem(key: "n", label: "next tab", isMode: false),
            HUDItem(key: "1–9", label: "tab 1–9", isMode: false),
            HUDItem(key: "u", label: "take out", isMode: false),
        ])
    }

    @Test func shortOrIrregularRunsStayAsTheyAre() {
        let two = (1...2).map { HUDItem(key: "\($0)", label: "tab \($0)", isMode: false) }
        #expect(KeyRouter.foldNumberRuns(two) == two)
        let mixed = [HUDItem(key: "1", label: "tab 1", isMode: false), HUDItem(key: "2", label: "workspace 2", isMode: false),
                     HUDItem(key: "3", label: "tab 3", isMode: false)]
        #expect(KeyRouter.foldNumberRuns(mixed) == mixed)
    }
}
