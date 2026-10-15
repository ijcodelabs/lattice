import Foundation

/// macOS 15+ has its own window tiling (drag to screen edges, ⌥-drag to snap into halves). It fights a
/// tiling WM: every mouse drag gets snapped by macOS first. Lattice only *reads* these settings; turning
/// them off is the user's choice (a button in the app's onboarding, or System Settings).
public enum MacTiling {
    static let domain = "com.apple.WindowManager"
    /// Settings keys and what System Settings → Desktop & Dock → Windows calls them.
    public static let settings: [(key: String, label: String)] = [
        ("EnableTilingByEdgeDrag", "Drag windows to screen edges to tile"),
        ("EnableTopTilingByEdgeDrag", "Drag windows to menu bar to fill screen"),
        ("EnableTilingOptionAccelerator", "Hold ⌥ key while dragging windows to tile"),
    ]

    /// Labels of the macOS tiling options that are on (absent = macOS default = on).
    public static var enabled: [String] {
        let d = UserDefaults(suiteName: domain)
        return settings.filter { d?.object(forKey: $0.key) as? Bool ?? true }.map(\.label)
    }

    /// Turn macOS tiling off (only call from an explicit user action).
    public static func disable() {
        for (key, _) in settings {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = ["write", domain, key, "-bool", "false"]
            try? p.run()
            p.waitUntilExit()
        }
    }
}
