/// A workspace and its tiles. A *tile* is one slot in the layout: either a single window or a
/// **group** (several windows sharing the slot, one shown at a time — Hyprland groups / i3 tabbed).
/// Layouts and the tree only ever see tile ids, so they need no knowledge of groups.

public enum GroupStyle: String, Codable, CaseIterable, Sendable {
    /// Titles side by side in one strip.
    case tabbed
    /// Titles listed one above another.
    case stacked
}

public struct WindowGroup: Hashable, Codable, Sendable {
    public var members: [WindowID]
    /// The member on screen; the others are parked.
    public var active: WindowID
    public var style: GroupStyle

    public init(members: [WindowID], active: WindowID, style: GroupStyle) {
        self.members = members; self.active = active; self.style = style
    }
}

public struct Workspace: Hashable, Sendable {
    public let name: String
    public var layout: LayoutKind
    public var ratio: Double
    /// Tiles in layout order (window ids, or group ids like `group:3`). Canonical; `tree` is kept in sync
    /// so layout switches are lossless.
    public var order: [WindowID] = []
    public var tree = LayoutTree()
    /// Group tiles by id.
    public var groups: [WindowID: WindowGroup] = [:]
    /// Floating windows and their (on-screen) frames.
    public var floating: [WindowID: Rect] = [:]
    /// The focused *window* (never a group id).
    public var focused: WindowID?
    /// One-shot (i3-style): after `split` on a grouped window, the next new window opens as its own tile
    /// next to the group (this way) instead of joining it. Cleared by that window or a focus change.
    public var nextOutsideGroup: Orientation?
    /// The layout before the last switch — `layout monocle` pressed again returns to it (mod+f toggles).
    public var previousLayout: LayoutKind?

    public init(name: String, layout: LayoutKind, ratio: Double) {
        self.name = name; self.layout = layout; self.ratio = ratio
    }

    /// Every window, grouped members included.
    public var windows: [WindowID] { order.flatMap { groups[$0]?.members ?? [$0] } + floating.keys.sorted() }

    /// The window a tile shows (a group's active member).
    public func shown(_ tile: WindowID) -> WindowID { groups[tile]?.active ?? tile }

    public func contains(_ id: WindowID) -> Bool { windows.contains(id) }

    /// The group containing a window.
    public func group(of id: WindowID) -> WindowID? { groups.first { $0.value.members.contains(id) }?.key }

    /// The tile a window (or tile id) occupies; nil for floating/unknown windows.
    public func tile(of id: WindowID) -> WindowID? { order.contains(id) ? id : group(of: id) }

    /// Focus a window; inside a group this also makes it the shown member.
    mutating func setFocused(_ id: WindowID?) {
        if let old = focused, let id, tile(of: old) != tile(of: id) { nextOutsideGroup = nil }
        focused = id
        if let id, let g = group(of: id) { groups[g]!.active = id }
    }

    // MARK: Tiles

    mutating func insertTile(_ tile: WindowID, afterTile: WindowID?) {
        guard !order.contains(tile) else { return }
        if let a = afterTile, let i = order.firstIndex(of: a) { order.insert(tile, at: i + 1) } else { order.append(tile) }
        tree.insert(tile, after: afterTile.flatMap { tree.contains($0) ? $0 : nil } ?? tree.leaves.last)
    }

    mutating func removeTile(_ tile: WindowID) {
        order.removeAll { $0 == tile }
        tree.remove(tile)
    }

    mutating func replaceTile(_ old: WindowID, with new: WindowID) {
        if let i = order.firstIndex(of: old) { order[i] = new }
        tree.rename(old, to: new)
    }

    /// Add a tiled window next to `after`. If `after` is a grouped window, the new window joins that group
    /// (like i3 / Hyprland: a window opened from a group stays in it) and becomes its shown member.
    mutating func addTiled(_ id: WindowID, after: WindowID?) {
        guard !contains(id) else { return }
        if let after, let g = group(of: after), nextOutsideGroup != nil {
            nextOutsideGroup = nil
            insertTile(id, afterTile: g)     // beside/below the group, as its own tile
            return
        }
        if let after, let g = group(of: after) {
            var grp = groups[g]!
            let i = grp.members.firstIndex(of: grp.active) ?? grp.members.count - 1
            grp.members.insert(id, at: i + 1)
            grp.active = id
            groups[g] = grp
            return
        }
        insertTile(id, afterTile: after.flatMap { tile(of: $0) })
    }

    /// Remove a window from wherever it is. A group that drops to one member dissolves into a plain tile;
    /// an empty group disappears.
    mutating func remove(_ id: WindowID) {
        floating[id] = nil
        if let g = group(of: id) {
            var grp = groups[g]!
            let i = grp.members.firstIndex(of: id)!
            let before = grp.members.count
            grp.members.remove(at: i)
            if grp.members.isEmpty {
                groups[g] = nil
                removeTile(g)
                return
            }
            if grp.active == id { grp.active = grp.members[max(0, i - 1)] }
            groups[g] = grp
            if before == 2 { dissolve(g) }
            return
        }
        removeTile(id)
    }

    /// Turn a group back into one tile per member, in place.
    mutating func dissolve(_ g: WindowID) {
        guard let grp = groups[g], let first = grp.members.first else { return }
        groups[g] = nil
        replaceTile(g, with: first)
        var prev = first
        for m in grp.members.dropFirst() {
            if let i = order.firstIndex(of: prev) { order.insert(m, at: i + 1) }
            tree.insert(m, after: prev)
            prev = m
        }
    }

    /// Make window `id`'s own tile into a group of one (new windows opened from it then join it).
    mutating func wrapInGroup(_ id: WindowID, groupID: WindowID, style: GroupStyle) {
        guard order.contains(id) else { return }
        groups[groupID] = WindowGroup(members: [id], active: id, style: style)
        replaceTile(id, with: groupID)
    }

    /// Put window `id` into the tile `target` (a window or a group). A plain window target becomes a new group.
    mutating func join(_ id: WindowID, into target: WindowID, groupID: WindowID, style: GroupStyle) {
        if var grp = groups[target] {
            let i = grp.members.firstIndex(of: grp.active) ?? grp.members.count - 1
            grp.members.insert(id, at: i + 1)
            grp.active = id
            groups[target] = grp
        } else if order.contains(target) {
            groups[groupID] = WindowGroup(members: [target, id], active: id, style: style)
            replaceTile(target, with: groupID)
        }
    }
}
