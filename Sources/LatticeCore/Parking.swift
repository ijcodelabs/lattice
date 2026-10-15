/// Parking = hiding a window of an inactive workspace by moving it (almost) off-screen.
///
/// macOS window-server rules measured on 2026-10-14 (Zen, System Settings, Ghostty — identical; memory/gotchas.md #6):
/// - x: a window entirely off-screen is pulled back to show 40pt; ≥1pt on-screen is accepted.
/// - y: the top edge is clamped to [visibleFrame.minY, visibleFrame.maxY − titleBarHeight] — the title bar
///   must stay below the menu bar and above the Dock. Off-screen in y is impossible.
/// ⇒ `.sliver` in a bottom corner: a 1pt-wide strip of title-bar height, inside the Dock area.

public enum ParkingStrategy: String, Codable, CaseIterable, Sendable {
    /// Fully outside every display. Kept only for experiments: macOS pulls it back to a 40pt-wide strip.
    case offscreen
    /// Leave a 1pt sliver at the home display's corner (the production strategy, AeroSpace-style).
    case sliver
}

public enum Corner: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft
}

public struct ParkingPlan: Codable, Hashable, Sendable {
    public var strategy: ParkingStrategy
    public var corner: Corner
    public var frame: Rect
}

public enum Parking {
    /// Points left visible with `.sliver`.
    public static let sliver: Double = 1

    /// Corners are tried in this order; bottom corners first so a stray sliver sits away from the menu bar.
    public static let cornerPreference: [Corner] = [.bottomRight, .bottomLeft, .topRight, .topLeft]

    public static let defaultStrategy: ParkingStrategy = .sliver

    /// Where to park a window of `size` that lives on `home`.
    /// The parked window must never land on another display, otherwise the "hidden" window shows up there.
    /// Returns nil when no corner of `home` is free of neighbouring displays.
    public static func plan(
        size: Size, home: Display, displays: [Display], strategy: ParkingStrategy = defaultStrategy,
        corners: [Corner] = cornerPreference
    ) -> ParkingPlan? {
        let others = displays.filter { $0.id != home.id }
        for corner in corners {
            let frame = parkedFrame(size: size, display: home.frame, corner: corner, strategy: strategy)
            let footprint = possibleFootprint(of: frame, home: home)
            if !others.contains(where: { footprint.intersects($0.frame) }) {
                return ParkingPlan(strategy: strategy, corner: corner, frame: frame)
            }
        }
        return nil
    }

    /// Everywhere the window may actually end up after macOS clamps y (top edge pushed into the visible frame,
    /// by an amount depending on the unknown title-bar height): the requested x-span, swept vertically from the
    /// visible frame's top to the requested bottom. Checking neighbours against the *requested* frame alone
    /// would miss a shorter display beside `home`.
    static func possibleFootprint(of requested: Rect, home: Display) -> Rect {
        let top = min(requested.minY, home.visibleFrame.minY)
        let bottom = max(requested.maxY, home.visibleFrame.minY + requested.height)
        return Rect(x: requested.minX, y: top, width: requested.width, height: bottom - top)
    }

    static func parkedFrame(size: Size, display d: Rect, corner: Corner, strategy: ParkingStrategy) -> Rect {
        // `inset` = how much of the window stays on the display at that corner.
        let inset = strategy == .sliver ? sliver : 0
        let x: Double, y: Double
        switch corner {
        case .bottomRight: x = d.maxX - inset; y = d.maxY - inset
        case .bottomLeft: x = d.minX - size.width + inset; y = d.maxY - inset
        case .topRight: x = d.maxX - inset; y = d.minY - size.height + inset
        case .topLeft: x = d.minX - size.width + inset; y = d.minY - size.height + inset
        }
        return Rect(origin: Point(x: x, y: y), size: size)
    }
}

extension Parking {
    /// Widest strip (in points) we accept as "hidden". macOS keeps part of a window on screen
    /// (memory/gotchas.md #6), so "fully off-screen" is not a usable criterion.
    public static let maxHiddenStrip: Double = 2

    /// True when whatever remains visible is only a thin strip (≤ `maxHiddenStrip` in one dimension).
    public static func isEffectivelyHidden(_ frame: Rect, displays: [Display]) -> Bool {
        displays.allSatisfy { d in
            guard let piece = frame.intersection(d.frame) else { return true }
            return piece.width <= maxHiddenStrip || piece.height <= maxHiddenStrip
        }
    }
}

/// How an app reacted to a frame request.
public enum FrameOutcome: String, Codable, Sendable {
    /// Observed frame matches the request.
    case honored
    /// App/OS moved it somewhere else (e.g. pulled back on-screen).
    case clamped
    /// Nothing changed.
    case ignored
    /// AX call failed or timed out.
    case failed
}

public enum FrameClassifier {
    public static func classify(requested: Rect, before: Rect, observed: Rect?, tolerance: Double = 2) -> FrameOutcome {
        guard let observed else { return .failed }
        // Size is often clamped independently of position; parking only cares about the origin.
        let posOK = abs(observed.minX - requested.minX) <= tolerance && abs(observed.minY - requested.minY) <= tolerance
        if posOK { return .honored }
        if observed.approximatelyEquals(before, tolerance: tolerance) { return .ignored }
        return .clamped
    }
}
