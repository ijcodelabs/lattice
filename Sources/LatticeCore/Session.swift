import Foundation

/// Session persistence: a snapshot of Lattice's layout, and how to rebuild it from the windows that
/// come back (after restarting Lattice, or after a reboot when macOS/apps reopen their windows).
///
/// Window ids don't survive restarts, so every saved window is a *slot* with a fingerprint
/// (app, title, frame, order among its app's windows). Windows that appear are matched to slots;
/// the saved layout is rebuilt from the matched windows, pruned so missing ones leave no holes.

public struct SessionSettings: Hashable, Codable, Sendable {
    /// Rebuild the last layout when Lattice starts.
    public var restore: Bool
    /// Seconds to keep matching windows as they come back.
    public var grace: Double
    /// Store window titles (better matching). Off: match by app + order only; titles never hit the disk.
    public var saveTitles: Bool

    public init(restore: Bool = true, grace: Double = 60, saveTitles: Bool = true) {
        self.restore = restore; self.grace = grace; self.saveTitles = saveTitles
    }
}

/// One saved window: where it was and how to recognise it again.
public struct SavedWindow: Hashable, Codable, Sendable {
    /// The window's id in the saved layout (order, tree, groups refer to it).
    public var slot: WindowID
    public var bundleID: String?
    public var app: String
    public var title: String?
    public var frame: Rect
    /// Index among the same app's windows (left → right, top → bottom) — tie-breaker for equal titles.
    public var ordinal: Int
    public var workspace: String

    /// Apps are compared by bundle id when known, else by name.
    public var appKey: String { bundleID ?? app }
}

public struct SessionSnapshot: Hashable, Codable, Sendable {
    public static let currentVersion = 1
    public var version = SessionSnapshot.currentVersion
    /// Seconds since 1970 (informational).
    public var savedAt: Double
    public var active: String
    /// Display name → workspace shown on it. Names, because display ids change between boots.
    public var visible: [String: String]
    /// Workspace → display name it lived on.
    public var assigned: [String: String]
    public var workspaces: [Workspace]
    public var windows: [SavedWindow]

    public init(savedAt: Double, active: String, visible: [String: String], assigned: [String: String],
                workspaces: [Workspace], windows: [SavedWindow]) {
        self.savedAt = savedAt; self.active = active; self.visible = visible; self.assigned = assigned
        self.workspaces = workspaces; self.windows = windows
    }
}

/// Matching windows to saved slots: best pairs first, one window per slot.
public enum SessionMatcher {
    /// Score of `w` for `slot` (nil = different app, never matches).
    public static func score(_ w: WindowSnapshot, ordinal: Int, _ slot: SavedWindow) -> Double? {
        guard (w.bundleID ?? w.app) == slot.appKey else { return nil }
        var s = 10.0
        if let t = slot.title, !t.isEmpty {
            if t == w.title { s += 100 } else { s += 60 * similarity(t, w.title) }
        }
        let d = hypot(w.frame.center.x - slot.frame.center.x, w.frame.center.y - slot.frame.center.y)
        s += 20 * max(0, 1 - d / 1500)
        if ordinal == slot.ordinal { s += 5 }
        return s
    }

    /// Token overlap (Jaccard) of two titles, 0…1. "Inbox – Mail" vs "Inbox (3) – Mail" ≈ 0.75.
    public static func similarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty || !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    /// Greedy global assignment: highest-scoring (window, slot) pairs first.
    public static func match(windows: [WindowSnapshot], slots: [SavedWindow]) -> [WindowID: WindowID] {
        let ordinals = Self.ordinals(windows)
        var pairs: [(score: Double, window: WindowID, slot: WindowID)] = []
        for w in windows {
            for s in slots {
                if let sc = score(w, ordinal: ordinals[w.id] ?? 0, s) { pairs.append((sc, w.id, s.slot)) }
            }
        }
        pairs.sort { ($0.score, $1.window, $1.slot) > ($1.score, $0.window, $0.slot) }
        var slotOf: [WindowID: WindowID] = [:], used = Set<WindowID>()
        for p in pairs where slotOf[p.window] == nil && !used.contains(p.slot) {
            slotOf[p.window] = p.slot
            used.insert(p.slot)
        }
        return slotOf   // window → slot
    }

    /// Index of each window among its app's windows, ordered left → right, top → bottom.
    public static func ordinals(_ windows: [WindowSnapshot]) -> [WindowID: Int] {
        var out: [WindowID: Int] = [:]
        for (_, group) in Dictionary(grouping: windows, by: { $0.bundleID ?? $0.app }) {
            for (i, w) in group.sorted(by: { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }).enumerated() {
                out[w.id] = i
            }
        }
        return out
    }
}

extension Workspace {
    /// Replace window ids (saved slots → live windows) everywhere in the workspace.
    mutating func rename(_ map: [WindowID: WindowID]) {
        guard !map.isEmpty else { return }
        func r(_ id: WindowID) -> WindowID { map[id] ?? id }
        // Two steps through unique temporaries so swaps/overlaps between old and new ids can't collide.
        let temp = Dictionary(uniqueKeysWithValues: map.keys.map { ($0, WindowID("tmp:" + $0.raw)) })
        for (old, t) in temp { tree.rename(old, to: t) }
        for (old, t) in temp { tree.rename(t, to: map[old]!) }
        order = order.map(r)
        for (g, grp) in groups {
            groups[g] = WindowGroup(members: grp.members.map(r), active: r(grp.active), style: grp.style)
        }
        floating = Dictionary(uniqueKeysWithValues: floating.map { (r($0.key), $0.value) })
        focused = focused.map(r)
    }

    /// Remove every window not in `keep` (groups dissolve/vanish as usual; the tree closes up).
    mutating func prune(keep: Set<WindowID>) {
        for id in windows where !keep.contains(id) { remove(id) }
        if let f = focused, !keep.contains(f) { focused = windows.first }
    }
}

extension Workspace: Codable {
    enum CodingKeys: String, CodingKey { case name, layout, ratio, order, tree, groups, floating, focused, previousLayout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), layout: try c.decode(LayoutKind.self, forKey: .layout),
                  ratio: try c.decode(Double.self, forKey: .ratio))
        order = try c.decode([WindowID].self, forKey: .order)
        tree = try c.decode(LayoutTree.self, forKey: .tree)
        groups = try c.decode([WindowID: WindowGroup].self, forKey: .groups)
        floating = try c.decode([WindowID: Rect].self, forKey: .floating)
        focused = try c.decodeIfPresent(WindowID.self, forKey: .focused)
        previousLayout = try c.decodeIfPresent(LayoutKind.self, forKey: .previousLayout)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(layout, forKey: .layout); try c.encode(ratio, forKey: .ratio)
        try c.encode(order, forKey: .order); try c.encode(tree, forKey: .tree); try c.encode(groups, forKey: .groups)
        try c.encode(floating, forKey: .floating); try c.encodeIfPresent(focused, forKey: .focused)
        try c.encodeIfPresent(previousLayout, forKey: .previousLayout)
    }
}

extension WindowID: CodingKeyRepresentable {
    public var codingKey: CodingKey { WindowIDKey(stringValue: raw)! }
    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }

    struct WindowIDKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
