import Foundation
import Testing
import LatticeCore
@testable import LatticeConfig

@Suite struct ConfigTests {
    @Test func builtInDefaultsParse() throws {
        let s = ConfigLoader.defaults
        #expect(s.mod == [.ctrl, .alt])
        #expect(s.defaultLayout == .dwindle)
        #expect(s.workspaces == (1...9).map(String.init))
        #expect(s.bindings.count > 40)
        #expect(s.bindings.contains(Binding(chord: KeyChord(modifiers: [.ctrl, .alt], key: "h"), command: .focus(.left))))
        #expect(s.bindings.contains(Binding(chord: KeyChord(modifiers: [.ctrl, .alt, .shift], key: "3"), command: .moveToWorkspace("3", follow: false))))
        #expect(s.rules.count == 2)
    }

    @Test func modIsAppliedRegardlessOfKeyOrder() throws {
        let s = try ConfigLoader.parse("""
            bindings:
              mod+h: focus left
            mod: cmd+shift
            """)
        #expect(s.bindings == [Binding(chord: KeyChord(modifiers: [.cmd, .shift], key: "h"), command: .focus(.left))])
    }

    @Test func emptyFileGivesDefaultSettingsWithoutBindings() throws {
        #expect(try ConfigLoader.parse("").bindings.isEmpty)
        #expect(try ConfigLoader.parse("# only a comment\n").gaps == Gaps(inner: 8, outer: 8))
    }

    func error(_ yaml: String) -> ConfigError? {
        do { _ = try ConfigLoader.parse(yaml, file: "t.yaml"); return nil } catch { return error }
    }

    @Test func strictModeRejectsYamlTraps() {
        #expect(error("workspaces: [no, yes]")?.message.contains("quote it") == true)          // Norway problem
        #expect(error("workspaces: [\"no\"]") == nil)                                           // quoted is fine
        #expect(error("gaps: &g {inner: 1}\nlayout: *g")?.message.contains("anchors") == true)
        #expect(error("gaps: !!map {inner: 1}")?.message.contains("explicit tags") == true)
        #expect(error("mod: !!str ctrl")?.message.contains("explicit tags") == true)
        #expect(error("gaps:\n  <<: {inner: 1}")?.message.contains("merge keys") == true)
        #expect(error("mod: ctrl\nmod: alt")?.message.contains("YAML syntax") == true)          // duplicate key (Yams)
    }

    @Test func schemaErrorsPointAtTheLine() throws {
        let e = try #require(error("""
            gaps:
              inner: 8
            bindings:
              mod+h: focus sideways
            """))
        #expect(e.line == 4)
        #expect(e.message.contains("left|right|up|down"))
        #expect(e.description.hasPrefix("t.yaml:4:"))

        #expect(error("colour: red")?.message.contains("unknown key 'colour'") == true)
        #expect(error("gaps: {inner: 500}")?.message.contains("between 0") == true)
        #expect(error("layout: {default: spiral}")?.message.contains("tree, dwindle") == true)
        #expect(error("focus-new-windows: yes")?.message.contains("true or false") == true)
        #expect(error("bindings:\n  ctrl+h: focus left\n  control+h: focus right")?.message.contains("same chord") == true)
        #expect(error("rules:\n  - match: {app: \"(\"}\n    float: true")?.message.contains("regular expression") == true)
        #expect(error("rules:\n  - float: true")?.message.contains("needs a match") == true)
        #expect(error("workspaces: [\"a b\"]")?.message.contains("spaces") == true)
    }
}

@Suite struct ModeConfigTests {
    @Test func defaultsHaveLeaderAndModes() throws {
        let s = ConfigLoader.defaults
        #expect(s.bindings.contains { $0.chord == KeyChord(modifiers: [.ctrl, .alt], key: "space") && $0.command == .mode("leader") })
        #expect(Set(s.modes.keys) == ["leader", "layout", "resize", "workspace", "display", "group"])
        let resize = try #require(s.modes["resize"])
        #expect(resize.sticky && resize.timeout == 0)
        let leader = try #require(s.modes["leader"])
        #expect(leader.bindings.first == Binding(chord: KeyChord(modifiers: [], key: "l"), command: .mode("layout"), label: "layout…"))
        #expect(s.modes["workspace"]!.bindings.contains { $0.chord.key == "1" && $0.command == .workspace("1") })
    }

    func error(_ yaml: String) -> ConfigError? {
        do { _ = try ConfigLoader.parse(yaml, file: "t.yaml"); return nil } catch { return error }
    }

    @Test func modeErrors() throws {
        let undefined = try #require(error("""
            bindings:
              mod+space: mode leadr
            """))
        #expect(undefined.message.contains("mode 'leadr' is not defined") && undefined.line == 2)

        let nested = try #require(error("""
            modes:
              leader:
                bindings:
                  l: mode nope
            """))
        #expect(nested.message.contains("'nope'") && nested.line == 4)

        #expect(error("modes:\n  empty: { label: x }")?.message.contains("no bindings") == true)
        #expect(error("modes:\n  m:\n    bindings: { a: { label: x } }")?.message.contains("needs a command") == true)
        #expect(error("modes:\n  m:\n    colour: red\n    bindings: { a: quit }")?.message.contains("unknown key 'colour'") == true)
        #expect(error("modes:\n  m:\n    bindings: { a: { command: fly } }")?.line == 3)
    }
}

@Suite struct ThemeAndBarConfigTests {
    func error(_ yaml: String, themesDir: URL? = nil) -> ConfigError? {
        do { _ = try ConfigLoader.parse(yaml, file: "t.yaml", themesDir: themesDir); return nil } catch { return error }
    }

    @Test func builtinThemesAllParse() throws {
        for name in BuiltinThemes.all.keys {
            let t = try ThemeLoader.builtin(name)
            #expect(t.name == name)
        }
        let nord = try ThemeLoader.builtin("nord")
        #expect(nord.light == nil && nord.dark.accent == RGBA.parse("#88c0d0"))
        #expect(try ThemeLoader.builtin("lattice").light != nil)
    }

    @Test func defaultsUseLatticeThemeAndBar() {
        let s = ConfigLoader.defaults
        #expect(s.theme.name == "lattice")
        #expect(s.borders.enabled)
        #expect(s.bar.enabled && s.bar.position == .top && s.bar.mode == .reserve && s.bar.height == 30)
        #expect(s.bar.left == [.workspaces(showEmpty: false), .mode, .layout])
        #expect(s.bar.center == [.focused(maxLength: 70)])
        #expect(s.bar.right.last == .clock(format: "EEE d MMM  HH:mm"))
        #expect(ConfigLoader.parse_empty().theme.name == "lattice")
    }

    @Test func userThemeFileWinsAndErrorsPointIntoIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            font: Menlo
            dark:
              background: "#000000"
              surface: "#111111"
              foreground: "#ffffff"
              muted: "#888888"
              accent: "#ff00ff"
              urgent: "#ff0000"
              border: "#ff00ff80"
            """.write(to: dir.appendingPathComponent("nord.yaml"), atomically: true, encoding: .utf8)
        let s = try ConfigLoader.parse("theme: nord", file: "t.yaml", themesDir: dir)
        #expect(s.theme.font == "Menlo" && s.theme.dark.border.a < 0.6)

        try "dark:\n  background: #000000\n".write(to: dir.appendingPathComponent("bad.yaml"), atomically: true, encoding: .utf8)
        let e = try #require(error("theme: bad", themesDir: dir))
        #expect(e.file.hasSuffix("bad.yaml") && e.message.contains("must be quoted") && e.line == 2)

        try "dark:\n  background: \"#000000\"\n".write(to: dir.appendingPathComponent("partial.yaml"), atomically: true, encoding: .utf8)
        #expect(error("theme: partial", themesDir: dir)?.message.contains("missing: surface") == true)

        let unknown = try #require(error("theme: solarized", themesDir: dir))
        #expect(unknown.file == "t.yaml" && unknown.line == 1 && unknown.message.contains("available:"))
    }

    @Test func barErrors() {
        #expect(error("bar: { position: left }")?.message.contains("top or bottom") == true)
        #expect(error("bar: { left: [weather] }")?.message.contains("unknown widget 'weather'") == true)
        #expect(error("bar: { left: [{ type: clock, colour: red }] }")?.message.contains("no option 'colour'") == true)
        #expect(error("bar: { left: [{ type: script }] }")?.message.contains("needs command") == true)
        #expect(error("bar: { left: [{ type: script, command: date, interval: 0 }] }")?.message.contains("interval") == true)
        #expect(error("bar: { left: [{ format: x }] }")?.message.contains("needs `type:`") == true)
        #expect(error("bar: { height: 5 }")?.message.contains("between 16") == true)
        #expect(error("borders: { enabled: maybe }")?.message.contains("true or false") == true)
    }

    @Test func scriptAndTextWidgets() throws {
        let s = try ConfigLoader.parse("""
            bar:
              right:
                - { type: script, command: "echo hi", interval: 5 }
                - { type: text, text: "λ" }
                - { type: workspaces, show-empty: true }
            """)
        #expect(s.bar.right == [.script(command: "echo hi", interval: 5), .text("λ"), .workspaces(showEmpty: true)])
        #expect(s.bar.enabled)   // a bar: section turns the bar on unless enabled: false
    }
}

extension ConfigLoader {
    static func parse_empty() -> Settings { try! parse("") }
}

@Suite struct DisplayConfigTests {
    @Test func workspaceDisplaysParse() throws {
        let s = try ConfigLoader.parse("""
            workspace-displays:
              "9": secondary
              "8": "DELL"
              "1": main
              "2": "2"
            """)
        #expect(s.workspaceDisplays == ["9": .secondary, "8": .name("DELL"), "1": .main, "2": .index(2)])
        #expect(ConfigLoader.defaults.workspaceDisplays.isEmpty)
        #expect(ConfigLoader.defaults.modes["display"] != nil)
        #expect(ConfigLoader.defaults.bindings.contains { $0.command == .focusDisplay(.next) })
    }

    @Test func workspaceDisplaysErrors() {
        do { _ = try ConfigLoader.parse("workspace-displays: [main]"); Issue.record("expected error") } catch {
            #expect(error.message.contains("must be a mapping"))
        }
    }
}

@Suite struct GroupConfigTests {
    @Test func groupsSectionAndDefaults() throws {
        let d = ConfigLoader.defaults
        #expect(d.groups == GroupSettings(tabBar: true, style: .tabbed, tabHeight: 26))
        #expect(d.bindings.contains { $0.chord == KeyChord(modifiers: [.ctrl, .alt], key: "rightbracket") && $0.command == .groupCycle(1) })
        #expect(d.modes["group"]!.bindings.contains { $0.command == .group(.left) })
        let s = try ConfigLoader.parse("groups: { tab-bar: false, style: stacked, tab-height: 30 }")
        #expect(s.groups == GroupSettings(tabBar: false, style: .stacked, tabHeight: 30))
        do { _ = try ConfigLoader.parse("groups: { style: tabs }"); Issue.record("expected error") } catch {
            #expect(error.message.contains("tabbed or stacked"))
        }
    }
}

@Suite struct FocusWrapConfigTests {
    @Test func focusWrapParses() throws {
        #expect(ConfigLoader.defaults.focusWrap)
        #expect(try ConfigLoader.parse("focus-wrap: false").focusWrap == false)
    }
}

@Suite struct GroupReorderConfigTests {
    @Test func defaultKeys() {
        let d = ConfigLoader.defaults
        #expect(d.bindings.contains { $0.chord == KeyChord(modifiers: [.ctrl, .alt, .shift], key: "rightbracket") && $0.command == .groupMove(.right) })
        #expect(d.modes["group"]!.bindings.contains { $0.chord == KeyChord(modifiers: [.shift], key: "h") && $0.command == .groupMove(.left) })
        #expect(d.modes["group"]!.bindings.contains { $0.chord.key == "9" && $0.command == .groupTab(9) })
    }
}

@Suite struct SessionConfigTests {
    @Test func sessionSection() throws {
        #expect(ConfigLoader.defaults.session == SessionSettings(restore: true, grace: 60, saveTitles: true))
        let s = try ConfigLoader.parse("session: { restore: false, grace: 10, save-titles: false }")
        #expect(s.session == SessionSettings(restore: false, grace: 10, saveTitles: false))
        do { _ = try ConfigLoader.parse("session: { grace: 9999 }"); Issue.record("expected error") } catch {
            #expect(error.message.contains("between 0"))
        }
    }
}
