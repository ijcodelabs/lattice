import Foundation

/// Geometry in **AX global coordinates**: origin at the top-left of the primary display, y grows down.
/// Our own types keep the core free of CoreGraphics/AppKit.

public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Size: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var area: Double { max(0, width) * max(0, height) }
}

public struct Rect: Codable, Hashable, Sendable, CustomStringConvertible {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var area: Double { size.area }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }
    public var center: Point { Point(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }

    /// Intersection, or nil when the rects don't overlap (touching edges don't count).
    public func intersection(_ other: Rect) -> Rect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func intersects(_ other: Rect) -> Bool { intersection(other) != nil }

    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }

    /// True when every edge is within `tolerance` points of `other`'s.
    public func approximatelyEquals(_ other: Rect, tolerance: Double = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String {
        func f(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        return "(\(f(minX)),\(f(minY)) \(f(width))×\(f(height)))"
    }
}

/// A physical display. `frame` is the full display, `visibleFrame` excludes the menu bar / Dock.
public struct Display: Codable, Hashable, Sendable {
    public var id: UInt32
    public var name: String
    public var frame: Rect
    public var visibleFrame: Rect
    public var isPrimary: Bool

    public init(id: UInt32, name: String, frame: Rect, visibleFrame: Rect, isPrimary: Bool) {
        self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame; self.isPrimary = isPrimary
    }
}

extension Rect {
    /// Area of this rect visible on any of the displays (displays never overlap).
    public func visibleArea(on displays: [Display]) -> Double {
        displays.reduce(0) { $0 + (intersection($1.frame)?.area ?? 0) }
    }

    /// Fraction [0, 1] of this rect visible on any display.
    public func visibleFraction(on displays: [Display]) -> Double {
        guard area > 0 else { return 0 }
        return min(1, visibleArea(on: displays) / area)
    }

    /// Largest single piece of this rect visible on one display (nil when fully off-screen).
    public func largestVisiblePiece(on displays: [Display]) -> Rect? {
        displays.compactMap { intersection($0.frame) }.max { $0.area < $1.area }
    }

    /// The display holding the largest part of this rect (nil when fully off-screen).
    public func dominantDisplay(in displays: [Display]) -> Display? {
        displays
            .map { ($0, intersection($0.frame)?.area ?? 0) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}
