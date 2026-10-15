/// Rescue = guarantee every window can be brought back, whatever happened (crash, bad parking, display unplugged).

public enum Rescue {
    /// A window counts as stranded when less than this fraction of it is on any display…
    public static let minVisibleFraction = 0.3
    /// …or less than this many points in either dimension are visible.
    public static let minVisibleExtent = 80.0

    public static func isStranded(_ frame: Rect, displays: [Display]) -> Bool {
        guard !displays.isEmpty, !frame.isEmpty else { return false }
        if frame.visibleFraction(on: displays) < minVisibleFraction { return true }
        let biggestPiece = displays.compactMap { frame.intersection($0.frame) }.max { $0.area < $1.area }
        guard let piece = biggestPiece else { return true }
        return piece.width < minVisibleExtent || piece.height < minVisibleExtent
    }

    /// Conservative on-screen frame: centred on the primary display's visible area, shrunk to fit.
    public static func rescueFrame(for frame: Rect, displays: [Display]) -> Rect? {
        guard let target = displays.first(where: \.isPrimary) ?? displays.first else { return nil }
        let area = target.visibleFrame
        let w = min(frame.width, area.width * 0.9)
        let h = min(frame.height, area.height * 0.9)
        return Rect(x: area.minX + (area.width - w) / 2, y: area.minY + (area.height - h) / 2, width: w, height: h)
    }
}
