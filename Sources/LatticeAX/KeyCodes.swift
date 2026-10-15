import Carbon.HIToolbox
import LatticeCore

/// Key name → virtual key code, honouring the current keyboard layout for characters
/// (on Croatian/German QWERTZ, `z` is where US has `y`). Named keys use fixed codes.
public enum KeyCodes {
    static let named: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    /// Punctuation key names → the character they stand for.
    static let punctuation: [String: Character] = [
        "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "grave": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    /// US-ANSI positions: the fallback when the current layout can't type a character unshifted.
    static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    public struct Resolution: Sendable {
        public let code: UInt16
        /// True when the current layout couldn't type it and we fell back to the US position.
        public let fallback: Bool
    }

    /// Resolve a `KeyChord.key` name.
    public static func resolve(_ key: String, layout: [Character: UInt16] = currentLayoutMap()) -> Resolution? {
        if let code = named[key] { return Resolution(code: code, fallback: false) }
        guard let ch = punctuation[key] ?? (key.count == 1 ? Character(key) : nil) else { return nil }
        if let code = layout[ch] { return Resolution(code: code, fallback: false) }
        return ansi[ch].map { Resolution(code: $0, fallback: true) }
    }

    /// Character produced by each key code (no modifiers) on the current ASCII-capable keyboard layout.
    public static func currentLayoutMap() -> [Character: UInt16] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [Character: UInt16] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                )
                guard status == noErr, length == 1, let s = String(utf16CodeUnits: chars, count: 1).lowercased().first else { continue }
                if map[s] == nil || named.values.contains(map[s]!) { map[s] = code }
            }
        }
        return map
    }

    /// Key code → key name (the inverse of `resolve`) for the current layout: named keys by fixed code,
    /// characters by what the layout types, punctuation by its name (`-` → `minus`).
    public static func names(layout: [Character: UInt16] = currentLayoutMap()) -> [UInt16: String] {
        var out: [UInt16: String] = [:]
        let punctuationNames = Dictionary(uniqueKeysWithValues: punctuation.map { ($0.value, $0.key) })
        for (ch, code) in ansi where out[code] == nil { out[code] = punctuationNames[ch] ?? String(ch) }
        for (ch, code) in layout { out[code] = punctuationNames[ch] ?? String(ch) }   // the real layout wins
        for (name, code) in named { out[code] = name }
        return out
    }

    /// Secure Input (password fields, some terminals) blocks event taps from seeing keys.
    public static var secureInputEnabled: Bool { IsSecureEventInputEnabled() }
}
