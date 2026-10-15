import AppKit
import LatticeCore

public enum Displays {
    /// All displays in **AX global coordinates** (top-left of primary, y down).
    /// NSScreen uses bottom-left origin with y up — this is the only place we convert (memory/gotchas.md #1).
    @MainActor
    public static func current() -> [Display] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height

        func toAX(_ r: CGRect) -> Rect {
            Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }

        return screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Display(
                id: id,
                name: screen.localizedName,
                frame: toAX(screen.frame),
                visibleFrame: toAX(screen.visibleFrame),
                isPrimary: index == 0
            )
        }
    }
}
