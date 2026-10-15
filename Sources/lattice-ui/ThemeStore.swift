import AppKit
import LatticeCore
import SwiftUI

/// Current theme + macOS appearance. Every view observes it, so a theme reload or a light/dark switch
/// re-renders the bar, HUD, palette and border at once.
@MainActor
final class ThemeStore: ObservableObject {
    @Published var theme: Theme = .fallback
    @Published private(set) var isDark = ThemeStore.systemIsDark()
    private var observer: NSObjectProtocol?

    init() {
        // Posted when the user flips light/dark (or Auto switches).
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDark = ThemeStore.systemIsDark() }
        }
    }

    static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var palette: ThemePalette { theme.palette(dark: isDark) }

    func font(_ scale: Double = 1, weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        let size = theme.fontSize * scale
        if let family = theme.font { return .custom(family, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: mono ? .monospaced : .default)
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// AX coordinates (top-left of the primary display, y down) → Cocoa screen coordinates (bottom-left, y up).
func cocoaRect(_ r: Rect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

/// Panel background: a behind-window blur (like native macOS panels) under the theme colour,
/// so whatever is behind a translucent HUD/palette is softened, never crisp (borders, text).
struct ThemedPanelBackground: View {
    @ObservedObject var store: ThemeStore
    var radius: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            VisualEffectBlur().clipShape(shape)
            shape.fill(store.palette.background.color.opacity(store.theme.opacity))
            shape.strokeBorder(store.palette.surface.color)
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
