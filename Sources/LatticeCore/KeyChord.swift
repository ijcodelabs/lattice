/// A key combination like `ctrl+alt+h`. Key names are layout-independent *characters/names*;
/// the AX edge resolves them to key codes for the current keyboard layout.
public struct KeyChord: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let cmd = Modifiers(rawValue: 1 << 0)
        public static let ctrl = Modifiers(rawValue: 1 << 1)
        public static let alt = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var modifiers: Modifiers
    /// Normalised key name: a single character (`h`, `1`, `[`) or a named key (see `namedKeys`).
    public var key: String

    public init(modifiers: Modifiers, key: String) { self.modifiers = modifiers; self.key = key }

    /// Keys that aren't a single printable character.
    public static let namedKeys: Set<String> = Set([
        "return", "enter", "tab", "space", "escape", "backspace", "delete",
        "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
        "minus", "equal", "comma", "period", "slash", "backslash", "semicolon", "quote", "grave",
        "leftbracket", "rightbracket",
    ] + (1...20).map { "f\($0)" })

    /// Punctuation characters are stored by name, matching what the key tap reports.
    public static let punctuationNames: [String: String] = [
        "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", "\\": "backslash",
        ";": "semicolon", "'": "quote", "`": "grave", "[": "leftbracket", "]": "rightbracket",
    ]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownModifier(String)
        case unknownKey(String)
        case noKey
        case duplicateModifier(String)

        public var description: String {
            switch self {
            case .empty: "empty key chord"
            case let .unknownModifier(m): "unknown modifier '\(m)' (cmd, ctrl, alt, shift, mod)"
            case let .unknownKey(k): "unknown key '\(k)' (a single character, or one of: \(KeyChord.namedKeys.sorted().joined(separator: ", ")))"
            case .noKey: "chord has modifiers but no key"
            case let .duplicateModifier(m): "modifier '\(m)' given twice"
            }
        }
    }

    /// Parses `mod+shift+h`. `mod` expands to the user's configured main modifier set.
    public static func parse(_ text: String, mod: Modifiers) throws(ParseError) -> KeyChord {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !text.isEmpty else { throw .empty }
        // "ctrl++" → key "+"
        var tokens = parts
        if text.hasSuffix("++") { tokens = Array(parts.dropLast(2)) + ["+"] }
        guard let key = tokens.last, !key.isEmpty else { throw .noKey }
        var mods: Modifiers = []
        for m in tokens.dropLast() {
            let add: Modifiers
            switch m {
            case "cmd", "command", "super": add = .cmd
            case "ctrl", "control": add = .ctrl
            case "alt", "opt", "option": add = .alt
            case "shift": add = .shift
            case "mod": add = mod
            case "hyper": add = [.cmd, .ctrl, .alt, .shift]
            default: throw .unknownModifier(m)
            }
            if !mods.isDisjoint(with: add), m != "mod" { throw .duplicateModifier(m) }
            mods.formUnion(add)
        }
        let normalized = key == "enter" ? "return" : (punctuationNames[key] ?? key)
        guard normalized.count == 1 || namedKeys.contains(normalized) else { throw .unknownKey(key) }
        return KeyChord(modifiers: mods, key: normalized)
    }

    /// Parses just a modifier set like `ctrl+alt` (for the `mod:` setting).
    public static func parseModifiers(_ text: String) throws(ParseError) -> Modifiers {
        var mods: Modifiers = []
        for m in text.lowercased().split(separator: "+").map(String.init) {
            switch m {
            case "cmd", "command", "super": mods.insert(.cmd)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            case "hyper": mods.formUnion([.cmd, .ctrl, .alt, .shift])
            default: throw .unknownModifier(m)
            }
        }
        if mods.isEmpty { throw .empty }
        return mods
    }

    /// Mac-style display form for HUDs: `⌃⌥⇧←`, `↩`, `=`.
    public var symbol: String {
        var s = ""
        if modifiers.contains(.ctrl) { s += "⌃" }
        if modifiers.contains(.alt) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.cmd) { s += "⌘" }
        return s + (Self.keySymbols[key] ?? key)
    }

    static let keySymbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "␣",
        "escape": "esc", "backspace": "⌫", "delete": "⌦", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "grave": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.cmd) { parts.append("cmd") }
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }
}
