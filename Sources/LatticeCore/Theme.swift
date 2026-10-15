/// Design tokens shared by the HUD, palette, focus borders and bar.

public struct RGBA: Hashable, Codable, Sendable, CustomStringConvertible {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    public static func parse(_ text: String) -> RGBA? {
        guard text.hasPrefix("#") else { return nil }
        var hex = String(text.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let has = hex.count == 8
        let r = Double((v >> (has ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (has ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (has ? 8 : 0)) & 0xFF) / 255
        let a = has ? Double(v & 0xFF) / 255 : 1
        return RGBA(r: r, g: g, b: b, a: a)
    }

    public var description: String {
        func h(_ x: Double) -> String {
            let v = Int((x * 255).rounded())
            return (v < 16 ? "0" : "") + String(v, radix: 16)
        }
        return "#" + h(r) + h(g) + h(b) + (a < 1 ? h(a) : "")
    }
}

public struct ThemePalette: Hashable, Codable, Sendable {
    /// Bar / HUD / palette background.
    public var background: RGBA
    /// Raised elements: key caps, active workspace pill, selection.
    public var surface: RGBA
    public var foreground: RGBA
    /// Secondary text.
    public var muted: RGBA
    /// Highlights: active workspace, modes, palette selection.
    public var accent: RGBA
    /// Warnings: low battery, errors.
    public var urgent: RGBA
    /// The focus border.
    public var border: RGBA

    public init(background: RGBA, surface: RGBA, foreground: RGBA, muted: RGBA, accent: RGBA, urgent: RGBA, border: RGBA) {
        self.background = background; self.surface = surface; self.foreground = foreground; self.muted = muted
        self.accent = accent; self.urgent = urgent; self.border = border
    }

    public static let tokenNames = ["background", "surface", "foreground", "muted", "accent", "urgent", "border"]
}

public struct Theme: Hashable, Codable, Sendable {
    public var name: String
    /// Used in dark mode, and in light mode when `light` is nil.
    public var dark: ThemePalette
    /// Optional palette for macOS light appearance.
    public var light: ThemePalette?
    /// Font family for the bar/HUD/palette; nil = system font.
    public var font: String?
    public var fontSize: Double
    /// Corner radius of bar, HUD and palette.
    public var radius: Double
    public var borderWidth: Double
    /// Corner radius of the focus border (match your windows: macOS uses ~10–16).
    public var borderRadius: Double
    /// Background opacity of bar/HUD/palette (0.5–1).
    public var opacity: Double

    public init(
        name: String, dark: ThemePalette, light: ThemePalette? = nil, font: String? = nil, fontSize: Double = 13,
        radius: Double = 10, borderWidth: Double = 3, borderRadius: Double = 12, opacity: Double = 0.94
    ) {
        self.name = name; self.dark = dark; self.light = light; self.font = font; self.fontSize = fontSize
        self.radius = radius; self.borderWidth = borderWidth; self.borderRadius = borderRadius; self.opacity = opacity
    }

    public func palette(dark isDark: Bool) -> ThemePalette { isDark ? dark : (light ?? dark) }
}

extension Theme {
    /// Used when nothing else is configured (the real built-ins live in LatticeConfig as YAML).
    public static let fallback = Theme(
        name: "fallback",
        dark: ThemePalette(
            background: RGBA(r: 0.12, g: 0.12, b: 0.14), surface: RGBA(r: 0.22, g: 0.22, b: 0.25),
            foreground: RGBA(r: 0.93, g: 0.93, b: 0.95), muted: RGBA(r: 0.6, g: 0.6, b: 0.65),
            accent: RGBA(r: 0.35, g: 0.6, b: 1), urgent: RGBA(r: 1, g: 0.35, b: 0.35), border: RGBA(r: 0.35, g: 0.6, b: 1)
        )
    )
}
