import Foundation
import LatticeCore
import Yams

/// Themes: built-in YAML (BuiltinThemes) or `themes/NAME.yaml` next to the config (user file wins).
public enum ThemeLoader {
    /// Names available: built-ins plus user files.
    public static func available(themesDir: URL?) -> [String] {
        var names = Set(BuiltinThemes.all.keys)
        if let dir = themesDir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".yaml") { names.insert(String(f.dropLast(5))) }
        }
        return names.sorted()
    }

    public static func resolve(_ name: String, themesDir: URL?) throws(ConfigError) -> Theme {
        if let dir = themesDir {
            let url = dir.appendingPathComponent("\(name).yaml")
            if FileManager.default.fileExists(atPath: url.path) {
                let text: String
                do { text = try String(contentsOf: url, encoding: .utf8) } catch {
                    throw ConfigError(message: "cannot read: \(error.localizedDescription)", file: url.path)
                }
                return try parse(text, name: name, file: url.path)
            }
        }
        guard BuiltinThemes.all[name] != nil else {
            throw ConfigError(message: "unknown theme '\(name)' (available: \(available(themesDir: themesDir).joined(separator: ", ")))",
                              file: "")
        }
        return try builtin(name)
    }

    public static func builtin(_ name: String) throws(ConfigError) -> Theme {
        guard let yaml = BuiltinThemes.all[name] else { throw ConfigError(message: "no built-in theme '\(name)'", file: "<built-in>") }
        return try parse(yaml, name: name, file: "<built-in theme \(name)>")
    }

    public static func parse(_ yaml: String, name: String, file: String) throws(ConfigError) -> Theme {
        try ConfigLoader.withDocument(yaml, file: file) { root throws(ConfigError) -> Theme in
            let r = Reader(file: file)
            guard let root else { throw ConfigError(message: "empty theme", file: file) }
            try r.strict(root)
            var theme = Theme.fallback
            theme.name = name
            var dark: ThemePalette?
            let keys = ["font", "font-size", "radius", "border-width", "border-radius", "opacity", "dark", "light"]
            for (k, _, v) in try r.mapping(root, "the theme", allowed: keys) {
                switch k {
                case "font": theme.font = try r.string(v, "font")
                case "font-size": theme.fontSize = try r.number(v, "font-size", range: 8...32)
                case "radius": theme.radius = try r.number(v, "radius", range: 0...30)
                case "border-width": theme.borderWidth = try r.number(v, "border-width", range: 0...20)
                case "border-radius": theme.borderRadius = try r.number(v, "border-radius", range: 0...40)
                case "opacity": theme.opacity = try r.number(v, "opacity", range: 0.3...1)
                case "dark": dark = try palette(v, "dark", r)
                default: theme.light = try palette(v, "light", r)
                }
            }
            guard let dark else { throw r.fail(root, "a theme needs a dark: palette (light: is optional)") }
            theme.dark = dark
            return theme
        }
    }

    static func palette(_ node: Node, _ what: String, _ r: Reader) throws(ConfigError) -> ThemePalette {
        var colors: [String: RGBA] = [:]
        for (k, _, v) in try r.mapping(node, what, allowed: ThemePalette.tokenNames) {
            // An unquoted #hex is a YAML comment → empty value. Say so.
            if case let .scalar(s) = v, s.style == .plain, s.string.isEmpty || s.string == "~" {
                throw r.fail(v, "\(what).\(k): colours must be quoted, e.g. \(k): \"#88c0d0\"")
            }
            let text = try r.string(v, "\(what).\(k)")
            guard let c = RGBA.parse(text) else { throw r.fail(v, "\(what).\(k): '\(text)' is not a #rrggbb or #rrggbbaa colour") }
            colors[k] = c
        }
        let missing = ThemePalette.tokenNames.filter { colors[$0] == nil }
        guard missing.isEmpty else { throw r.fail(node, "\(what) is missing: \(missing.joined(separator: ", "))") }
        return ThemePalette(background: colors["background"]!, surface: colors["surface"]!, foreground: colors["foreground"]!,
                            muted: colors["muted"]!, accent: colors["accent"]!, urgent: colors["urgent"]!, border: colors["border"]!)
    }
}
