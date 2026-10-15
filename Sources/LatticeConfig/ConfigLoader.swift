import Foundation
import LatticeCore
import Yams

/// A config problem, pointing at the offending spot.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var line: Int?
    public var column: Int?
    public var file: String

    public var description: String {
        let at = line.map { ":\($0)\(column.map { ":\($0)" } ?? "")" } ?? ""
        return "\(file)\(at): \(message)"
    }
}

/// Strict YAML → `Settings`.
///
/// Strict mode (docs/idea.md §6): no anchors/aliases/merge keys, no explicit tags, no unknown keys,
/// no duplicate keys (Yams already rejects those), and no YAML-1.1 boolean/null words where a string
/// is expected — `no`, `on`, `yes`, `off`, `~` must be quoted. Every error carries line:column.
public enum ConfigLoader {
    public static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("lattice/config.yaml")
    }

    /// Built-in defaults (parsing the documented default config — it must always be valid).
    public static var defaults: Settings {
        // swiftlint:disable:next force_try
        try! parse(DefaultConfig.yaml, file: "<built-in>")
    }

    /// Loads `url`; a missing file means built-in defaults.
    public static func load(from url: URL = defaultURL) throws(ConfigError) -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw ConfigError(message: "cannot read: \(error.localizedDescription)", file: url.path)
        }
        return try parse(text, file: url.path, themesDir: themesDir(for: url))
    }

    /// User themes live next to the config: `~/.config/lattice/themes/NAME.yaml`.
    public static func themesDir(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
    }

    public static func parse(_ yaml: String, file: String = "config.yaml", themesDir: URL? = nil) throws(ConfigError) -> Settings {
        try withDocument(yaml, file: file) { root throws(ConfigError) -> Settings in
            var r = Reader(file: file, themesDir: themesDir)
            guard let root else {
                var s = Settings()
                s.theme = try ThemeLoader.builtin("lattice")
                return s
            }
            return try r.settings(root)
        }
    }

    /// Parse YAML and hand the root to `body` while keeping the parser alive: Yams holds anchors weakly on
    /// nodes and strongly only in the parser, and the strict check needs to see them (memory/gotchas.md #10).
    static func withDocument<T>(_ yaml: String, file: String, _ body: (Node?) throws(ConfigError) -> T) throws(ConfigError) -> T {
        let parser: Parser
        let root: Node?
        do {
            parser = try Parser(yaml: yaml)
            root = try parser.singleRoot()
        } catch {
            throw ConfigError(message: "YAML syntax: \(error)", file: file)
        }
        return try withExtendedLifetime(parser) { () throws(ConfigError) -> T in try body(root) }
    }
}

/// Walks the node tree with expected types; every failure is a `ConfigError` at the node's mark.
struct Reader {
    let file: String
    var themesDir: URL?

    func fail(_ node: Node?, _ message: String) -> ConfigError {
        ConfigError(message: message, line: node?.mark?.line, column: node?.mark?.column, file: file)
    }

    // MARK: Strictness

    func strict(_ node: Node) throws(ConfigError) {
        if case .alias = node { throw fail(node, "aliases (*name) are not allowed — repeat the value instead") }
        if node.anchor != nil { throw fail(node, "anchors (&name) are not allowed") }
        switch node {
        case let .scalar(s):
            let quoted = s.style == .singleQuoted || s.style == .doubleQuoted || s.style == .literal || s.style == .folded
            let ok = s.tag.rawValue.isEmpty || (s.tag.rawValue == Tag.Name.str.rawValue && quoted)
            if !ok { throw fail(node, "explicit tags (!!type) are not allowed") }
        case let .mapping(m):
            if !m.tag.rawValue.isEmpty { throw fail(node, "explicit tags (!!type) are not allowed") }
            for (k, v) in m {
                if k.scalar?.string == "<<" { throw fail(k, "merge keys (<<) are not allowed") }
                // Yams resolves mapping keys to !!str itself, so keys only get the anchor/alias check.
                if case .alias = k { throw fail(k, "aliases (*name) are not allowed") }
                if k.anchor != nil { throw fail(k, "anchors (&name) are not allowed") }
                try strict(v)
            }
        case let .sequence(s):
            if !s.tag.rawValue.isEmpty { throw fail(node, "explicit tags (!!type) are not allowed") }
            for v in s { try strict(v) }
        case .alias: break
        }
    }

    // MARK: Typed readers

    func mapping(_ node: Node, _ what: String, allowed: [String]) throws(ConfigError) -> [(key: String, keyNode: Node, value: Node)] {
        guard case let .mapping(m) = node else { throw fail(node, "\(what) must be a mapping (key: value)") }
        var out: [(String, Node, Node)] = []
        for (k, v) in m {
            guard case let .scalar(ks) = k else { throw fail(k, "keys must be plain text") }
            if !allowed.isEmpty, !allowed.contains(ks.string) {
                throw fail(k, "unknown key '\(ks.string)' in \(what) (allowed: \(allowed.joined(separator: ", ")))")
            }
            out.append((ks.string, k, v))
        }
        return out
    }

    static let yaml11Words: Set<String> = ["y", "n", "yes", "no", "on", "off", "true", "false", "null", "~"]

    func string(_ node: Node, _ what: String) throws(ConfigError) -> String {
        guard case let .scalar(s) = node else { throw fail(node, "\(what) must be text") }
        if s.style == .plain, Self.yaml11Words.contains(s.string.lowercased()) || s.string.isEmpty {
            throw fail(node, "\(what): '\(s.string)' is ambiguous in YAML — quote it (\"\(s.string)\")")
        }
        return s.string
    }

    func bool(_ node: Node, _ what: String) throws(ConfigError) -> Bool {
        guard case let .scalar(s) = node, s.style == .plain else { throw fail(node, "\(what) must be true or false") }
        switch s.string {
        case "true": return true
        case "false": return false
        default: throw fail(node, "\(what) must be true or false (not '\(s.string)')")
        }
    }

    func number(_ node: Node, _ what: String, range: ClosedRange<Double>) throws(ConfigError) -> Double {
        guard case let .scalar(s) = node, s.style == .plain, let v = Double(s.string) else {
            throw fail(node, "\(what) must be a number")
        }
        guard range.contains(v) else { throw fail(node, "\(what) must be between \(range.lowerBound) and \(range.upperBound)") }
        return v
    }

    // MARK: Schema

    static let topKeys = ["mod", "gaps", "layout", "workspaces", "focus-new-windows", "bindings", "modes", "rules",
                          "theme", "borders", "bar", "workspace-displays", "groups", "focus-wrap", "session"]

    mutating func settings(_ root: Node) throws(ConfigError) -> Settings {
        try strict(root)
        var s = Settings()
        s.theme = try ThemeLoader.builtin("lattice")
        var bindingsNode: Node?
        var modesNode: Node?
        for (key, _, value) in try mapping(root, "the config", allowed: Self.topKeys) {
            switch key {
            case "mod":
                let text = try string(value, "mod")
                do { s.mod = try KeyChord.parseModifiers(text) } catch { throw fail(value, "mod: \(error)") }
            case "gaps":
                for (k, _, v) in try mapping(value, "gaps", allowed: ["inner", "outer"]) {
                    let n = try number(v, "gaps.\(k)", range: 0...200)
                    if k == "inner" { s.gaps.inner = n } else { s.gaps.outer = n }
                }
            case "layout":
                for (k, _, v) in try mapping(value, "layout", allowed: ["default", "ratio"]) {
                    if k == "default" {
                        let name = try string(v, "layout.default")
                        guard let kind = LayoutKind(rawValue: name) else {
                            throw fail(v, "layout.default must be one of: \(LayoutKind.allCases.map(\.rawValue).joined(separator: ", "))")
                        }
                        s.defaultLayout = kind
                    } else {
                        s.ratio = try number(v, "layout.ratio", range: 0.1...0.9)
                    }
                }
            case "workspaces":
                guard case let .sequence(seq) = value, !seq.isEmpty else { throw fail(value, "workspaces must be a non-empty list") }
                var names: [String] = []
                for n in seq {
                    let name = try string(n, "workspace name")
                    guard !name.contains(where: \.isWhitespace) else { throw fail(n, "workspace names can't contain spaces") }
                    guard !names.contains(name) else { throw fail(n, "workspace '\(name)' listed twice") }
                    names.append(name)
                }
                s.workspaces = names
            case "focus-new-windows":
                s.focusNewWindows = try bool(value, "focus-new-windows")
            case "focus-wrap":
                s.focusWrap = try bool(value, "focus-wrap")
            case "session":
                for (k, _, v) in try mapping(value, "session", allowed: ["restore", "grace", "save-titles"]) {
                    switch k {
                    case "restore": s.session.restore = try bool(v, "session.restore")
                    case "grace": s.session.grace = try number(v, "session.grace", range: 0...600)
                    default: s.session.saveTitles = try bool(v, "session.save-titles")
                    }
                }
            case "bindings":
                bindingsNode = value // parsed after `mod` is known, whatever the key order
            case "modes":
                modesNode = value
            case "rules":
                s.rules = try rules(value)
            case "theme":
                let name = try string(value, "theme")
                do { s.theme = try ThemeLoader.resolve(name, themesDir: themesDir) } catch {
                    // Errors inside a theme file point into that file; a missing theme points here.
                    throw error.file.isEmpty ? fail(value, error.message) : error
                }
            case "borders":
                for (k, _, v) in try mapping(value, "borders", allowed: ["enabled"]) where k == "enabled" {
                    s.borders.enabled = try bool(v, "borders.enabled")
                }
            case "bar":
                s.bar = try bar(value)
            case "groups":
                for (k, _, v) in try mapping(value, "groups", allowed: ["tab-bar", "style", "tab-height"]) {
                    switch k {
                    case "tab-bar": s.groups.tabBar = try bool(v, "groups.tab-bar")
                    case "style":
                        let text = try string(v, "groups.style")
                        guard let st = GroupStyle(rawValue: text) else { throw fail(v, "groups.style must be tabbed or stacked") }
                        s.groups.style = st
                    default: s.groups.tabHeight = try number(v, "groups.tab-height", range: 16...48)
                    }
                }
            case "workspace-displays":
                for (ws, _, v) in try mapping(value, "workspace-displays", allowed: []) {
                    s.workspaceDisplays[ws] = DisplaySelector.parse(try string(v, "workspace-displays.\(ws)"))
                }
            default: break
            }
        }
        if let bindingsNode { s.bindings = try bindings(bindingsNode, mod: s.mod) }
        if let modesNode { s.modes = try modes(modesNode, mod: s.mod) }
        try checkModeReferences(s, bindingsNode: bindingsNode, modesNode: modesNode)
        return s
    }

    func bindings(_ node: Node, mod: KeyChord.Modifiers) throws(ConfigError) -> [Binding] {
        var out: [Binding] = []
        var seen: [KeyChord: String] = [:]
        for (key, keyNode, value) in try mapping(node, "bindings", allowed: []) {
            let chord: KeyChord
            do { chord = try KeyChord.parse(key, mod: mod) } catch { throw fail(keyNode, "binding '\(key)': \(error)") }
            if let other = seen[chord] { throw fail(keyNode, "'\(key)' is the same chord as '\(other)'") }
            seen[chord] = key
            let (command, label) = try bindingValue(value, key: key)
            out.append(Binding(chord: chord, command: command, label: label))
        }
        return out
    }

    /// A binding value is either `command text` or `{ command: text, label: text }`.
    func bindingValue(_ value: Node, key: String) throws(ConfigError) -> (Command, String?) {
        var text: String
        var label: String?
        var commandNode = value
        if case .mapping = value {
            var cmd: String?
            for (k, _, v) in try mapping(value, "binding '\(key)'", allowed: ["command", "label"]) {
                if k == "command" { cmd = try string(v, "binding '\(key)'.command"); commandNode = v } else { label = try string(v, "label") }
            }
            guard let cmd else { throw fail(value, "binding '\(key)' needs a command:") }
            text = cmd
        } else {
            text = try string(value, "binding '\(key)'")
        }
        do { return (try Command.parse(text), label) } catch { throw fail(commandNode, "binding '\(key)': \(error)") }
    }

    func modes(_ node: Node, mod: KeyChord.Modifiers) throws(ConfigError) -> [String: KeyMode] {
        var out: [String: KeyMode] = [:]
        for (name, nameNode, value) in try mapping(node, "modes", allowed: []) {
            guard !name.contains(where: \.isWhitespace) else { throw fail(nameNode, "mode names can't contain spaces") }
            var mode = KeyMode(name: name)
            for (k, _, v) in try mapping(value, "mode '\(name)'", allowed: ["label", "sticky", "timeout", "bindings"]) {
                switch k {
                case "label": mode.label = try string(v, "label")
                case "sticky": mode.sticky = try bool(v, "sticky")
                case "timeout": mode.timeout = try number(v, "timeout", range: 0...60)
                default: mode.bindings = try bindings(v, mod: mod)
                }
            }
            guard !mode.bindings.isEmpty else { throw fail(value, "mode '\(name)' has no bindings") }
            out[name] = mode
        }
        return out
    }

    /// Every `mode X` must name a defined mode — report it at the binding that says it.
    func checkModeReferences(_ s: Settings, bindingsNode: Node?, modesNode: Node?) throws(ConfigError) {
        func check(_ bindings: [Binding], in node: Node?) throws(ConfigError) {
            for b in bindings {
                guard case let .mode(target) = b.command, s.modes[target] == nil else { continue }
                let at = node?.mapping?.first { (try? KeyChord.parse($0.key.string ?? "", mod: s.mod)) == b.chord }?.value
                throw fail(at ?? node, "'\(b.chord)': mode '\(target)' is not defined under modes:")
            }
        }
        try check(s.bindings, in: bindingsNode)
        for (name, mode) in s.modes.sorted(by: { $0.key < $1.key }) {
            try check(mode.bindings, in: modesNode?.mapping?[Node(name)]?.mapping?[Node("bindings")])
        }
    }

    func rules(_ node: Node) throws(ConfigError) -> [WindowRule] {
        guard case let .sequence(seq) = node else { throw fail(node, "rules must be a list") }
        var out: [WindowRule] = []
        for item in seq {
            var rule = WindowRule()
            var hasMatch = false
            for (k, _, v) in try mapping(item, "a rule", allowed: ["match", "float", "workspace"]) {
                switch k {
                case "match":
                    for (mk, _, mv) in try mapping(v, "match", allowed: ["app", "bundle-id", "title"]) {
                        let text = try string(mv, "match.\(mk)")
                        if mk != "bundle-id", !WindowRule.isValidPattern(text) { throw fail(mv, "match.\(mk): invalid regular expression") }
                        switch mk {
                        case "app": rule.app = text
                        case "title": rule.title = text
                        default: rule.bundleID = text
                        }
                        hasMatch = true
                    }
                case "float": rule.float = try bool(v, "float")
                default: rule.workspace = try string(v, "workspace")
                }
            }
            guard hasMatch else { throw fail(item, "a rule needs a match: with app, bundle-id or title") }
            guard rule.float != nil || rule.workspace != nil else { throw fail(item, "a rule needs float: or workspace:") }
            out.append(rule)
        }
        return out
    }
}

// MARK: - Bar

extension Reader {
    func bar(_ node: Node) throws(ConfigError) -> BarSettings {
        var b = BarSettings(enabled: true)
        for (k, _, v) in try mapping(node, "bar", allowed: ["enabled", "position", "mode", "height", "left", "center", "right"]) {
            switch k {
            case "enabled": b.enabled = try bool(v, "bar.enabled")
            case "position":
                let p = try string(v, "bar.position")
                guard let pos = BarSettings.Position(rawValue: p) else { throw fail(v, "bar.position must be top or bottom") }
                b.position = pos
            case "mode":
                let m = try string(v, "bar.mode")
                guard let mode = BarSettings.Mode(rawValue: m) else { throw fail(v, "bar.mode must be reserve or overlay") }
                b.mode = mode
            case "height": b.height = try number(v, "bar.height", range: 16...80)
            case "left": b.left = try widgets(v, "bar.left")
            case "center": b.center = try widgets(v, "bar.center")
            default: b.right = try widgets(v, "bar.right")
            }
        }
        return b
    }

    func widgets(_ node: Node, _ what: String) throws(ConfigError) -> [BarWidget] {
        guard case let .sequence(seq) = node else { throw fail(node, "\(what) must be a list of widgets") }
        var out: [BarWidget] = []
        for item in seq { out.append(try widget(item, what)) }
        return out
    }

    /// `clock` or `{ type: clock, format: "HH:mm" }`.
    func widget(_ node: Node, _ what: String) throws(ConfigError) -> BarWidget {
        var type: String
        var props: [String: (key: Node, value: Node)] = [:]
        if case .mapping = node {
            var t: String?
            for (k, kn, v) in try mapping(node, "a widget", allowed: []) {
                if k == "type" { t = try string(v, "widget type") } else { props[k] = (kn, v) }
            }
            guard let t else { throw fail(node, "\(what): a widget mapping needs `type:` (\(BarWidget.names.joined(separator: ", ")))") }
            type = t
        } else {
            type = try string(node, "widget")
        }
        func only(_ allowed: [String]) throws(ConfigError) {
            for (k, p) in props where !allowed.contains(k) {
                throw fail(p.0, "widget '\(type)' has no option '\(k)'\(allowed.isEmpty ? "" : " (options: \(allowed.joined(separator: ", ")))")")
            }
        }
        func num(_ key: String, _ def: Double, _ range: ClosedRange<Double>) throws(ConfigError) -> Double {
            guard let p = props[key] else { return def }
            return try number(p.value, key, range: range)
        }
        func text(_ key: String) throws(ConfigError) -> String? {
            guard let p = props[key] else { return nil }
            return try string(p.value, key)
        }
        switch type {
        case "workspaces":
            try only(["show-empty"])
            let showEmpty = try props["show-empty"].map { p throws(ConfigError) in try bool(p.value, "show-empty") } ?? false
            return .workspaces(showEmpty: showEmpty)
        case "focused":
            try only(["max-length"])
            return .focused(maxLength: Int(try num("max-length", 60, 5...300)))
        case "layout": try only([]); return .layout
        case "mode": try only([]); return .mode
        case "clock":
            try only(["format"])
            return .clock(format: try text("format") ?? "EEE d MMM  HH:mm")
        case "battery": try only([]); return .battery
        case "cpu": try only([]); return .cpu
        case "memory": try only([]); return .memory
        case "script":
            try only(["command", "interval"])
            guard let cmd = try text("command") else { throw fail(node, "script widget needs command:") }
            return .script(command: cmd, interval: try num("interval", 10, 1...86400))
        case "text":
            try only(["text"])
            guard let t = try text("text") else { throw fail(node, "text widget needs text:") }
            return .text(t)
        default:
            throw fail(node, "\(what): unknown widget '\(type)' (\(BarWidget.names.joined(separator: ", ")))")
        }
    }
}
