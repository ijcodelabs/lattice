/// Identity of a managed window. Built at the AX edge as "pid:hash" (stable for the app's lifetime).
public struct WindowID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (a: WindowID, b: WindowID) -> Bool { a.raw < b.raw }
}

/// What the edge knows about a window when it appears.
public struct WindowSnapshot: Hashable, Codable, Sendable {
    public var id: WindowID
    public var pid: Int32
    public var app: String
    public var bundleID: String?
    public var title: String
    public var frame: Rect

    public init(id: WindowID, pid: Int32, app: String, bundleID: String?, title: String, frame: Rect) {
        self.id = id; self.pid = pid; self.app = app; self.bundleID = bundleID; self.title = title; self.frame = frame
    }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var axis: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// +1 when moving towards larger coordinates.
    public var sign: Double { self == .right || self == .down ? 1 : -1 }
}

/// `.horizontal` = children side by side (split along x), `.vertical` = stacked (split along y).
public enum Orientation: String, Codable, CaseIterable, Sendable {
    case horizontal, vertical
    public var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum LayoutKind: String, Codable, CaseIterable, Sendable {
    /// i3-style tree of splits.
    case tree
    /// Hyprland-style spiral: each new window halves the previous one along its longer side.
    case dwindle
    /// awesome-style: one master on the left, the rest stacked on the right.
    case master
    /// Every tiled window fills the area; only the focused one is on top.
    case monocle
}

public struct Gaps: Hashable, Codable, Sendable {
    public var inner: Double
    public var outer: Double
    public init(inner: Double, outer: Double) { self.inner = inner; self.outer = outer }
}
