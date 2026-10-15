/// Pure layout solvers: window order + area → frames.
public enum Layout {
    /// `ratio` = share of the first window at each step (dwindle) or of the master column (master).
    public static func frames(
        kind: LayoutKind, tree: LayoutTree, order: [WindowID], focused: WindowID?, area: Rect, ratio: Double, gaps: Gaps
    ) -> [WindowID: Rect] {
        // Outer gap shrinks the area by (outer − inner/2); each frame is then inset by inner/2,
        // which yields `outer` at the edges and `inner` between windows.
        let half = gaps.inner / 2
        let inner = innerArea(area, gaps)
        let raw: [WindowID: Rect] =
            switch kind {
            case .tree: tree.frames(in: inner)
            case .dwindle: dwindle(order, inner, ratio)
            case .master: master(order, inner, ratio)
            case .monocle: Dictionary(uniqueKeysWithValues: order.map { ($0, inner) })
            }
        return raw.mapValues { r in
            Rect(x: r.minX + half, y: r.minY + half, width: max(1, r.width - gaps.inner), height: max(1, r.height - gaps.inner))
        }
    }

    /// The area the solvers work in: `area` shrunk by (outer − inner/2) on every side.
    public static func innerArea(_ area: Rect, _ gaps: Gaps) -> Rect {
        let inset = max(0, gaps.outer - gaps.inner / 2)
        return Rect(x: area.minX + inset, y: area.minY + inset,
                    width: max(1, area.width - 2 * inset), height: max(1, area.height - 2 * inset))
    }

    /// The tree that produces exactly the same frames as `kind` (dwindle/master) for `order` in `area`.
    /// Dwindle is a chain of two-way splits along the longer side; master is master | stacked column.
    public static func equivalentTree(kind: LayoutKind, order: [WindowID], area: Rect, ratio: Double, gaps: Gaps) -> LayoutTree {
        let inner = innerArea(area, gaps)
        switch kind {
        case .dwindle:
            func chain(_ ids: ArraySlice<WindowID>, _ r: Rect) -> TreeNode {
                guard ids.count > 1, let first = ids.first else { return .leaf(ids.first!) }
                let horizontal = r.width >= r.height
                let rest = horizontal
                    ? Rect(x: r.minX + r.width * ratio, y: r.minY, width: r.width * (1 - ratio), height: r.height)
                    : Rect(x: r.minX, y: r.minY + r.height * ratio, width: r.width, height: r.height * (1 - ratio))
                return .split(Split(orientation: horizontal ? .horizontal : .vertical,
                                    children: [.leaf(first), chain(ids.dropFirst(), rest)], weights: [ratio, 1 - ratio]))
            }
            guard !order.isEmpty else { return LayoutTree() }
            switch chain(order[...], inner) {
            case let .split(s): return LayoutTree(root: s)
            case let .leaf(id): return LayoutTree(windows: [id])
            }
        case .master:
            guard let first = order.first else { return LayoutTree() }
            if order.count == 1 { return LayoutTree(windows: [first]) }
            let stack = Split(orientation: .vertical, children: order.dropFirst().map(TreeNode.leaf))
            return LayoutTree(root: Split(orientation: .horizontal, children: [.leaf(first), .split(stack)], weights: [ratio, 1 - ratio]))
        case .tree, .monocle:
            return LayoutTree(windows: order)
        }
    }

    static func dwindle(_ order: [WindowID], _ area: Rect, _ ratio: Double) -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        var rest = area
        for (i, id) in order.enumerated() {
            if i == order.count - 1 { out[id] = rest; break }
            // Split along the longer side, like Hyprland's dwindle.
            if rest.width >= rest.height {
                let w = rest.width * ratio
                out[id] = Rect(x: rest.minX, y: rest.minY, width: w, height: rest.height)
                rest = Rect(x: rest.minX + w, y: rest.minY, width: rest.width - w, height: rest.height)
            } else {
                let h = rest.height * ratio
                out[id] = Rect(x: rest.minX, y: rest.minY, width: rest.width, height: h)
                rest = Rect(x: rest.minX, y: rest.minY + h, width: rest.width, height: rest.height - h)
            }
        }
        return out
    }

    static func master(_ order: [WindowID], _ area: Rect, _ ratio: Double) -> [WindowID: Rect] {
        guard let first = order.first else { return [:] }
        if order.count == 1 { return [first: area] }
        var out: [WindowID: Rect] = [:]
        let mw = area.width * ratio
        out[first] = Rect(x: area.minX, y: area.minY, width: mw, height: area.height)
        let stack = order.dropFirst()
        let h = area.height / Double(stack.count)
        for (i, id) in stack.enumerated() {
            out[id] = Rect(x: area.minX + mw, y: area.minY + Double(i) * h, width: area.width - mw, height: h)
        }
        return out
    }

    /// Focus wrapping: the window at the far end in the *opposite* direction (e.g. `right` from the rightmost
    /// window → the leftmost), preferring windows level with `from` on the other axis.
    public static func wrapTarget(from: WindowID, _ direction: Direction, in frames: [WindowID: Rect]) -> WindowID? {
        guard let src = frames[from] else { return nil }
        let others = frames.filter { $0.key != from }
        guard !others.isEmpty else { return nil }
        func level(_ r: Rect) -> Bool {
            direction.axis == .horizontal ? r.minY < src.maxY && r.maxY > src.minY : r.minX < src.maxX && r.maxX > src.minX
        }
        let pool = others.filter { level($0.value) }.isEmpty ? others : others.filter { level($0.value) }
        // Position along the axis, measured so that "far side opposite to the direction" is the minimum.
        func along(_ r: Rect) -> Double { (direction.axis == .horizontal ? r.center.x : r.center.y) * direction.sign }
        func across(_ r: Rect) -> Double {
            direction.axis == .horizontal ? abs(r.center.y - src.center.y) : abs(r.center.x - src.center.x)
        }
        return pool.min { a, b in (along(a.value), across(a.value), a.key) < (along(b.value), across(b.value), b.key) }?.key
    }

    /// Nearest window from `from` in `direction`, by frame centres. Prefers windows that overlap on the
    /// perpendicular axis (true neighbours), then distance.
    public static func neighbour(of from: WindowID, _ direction: Direction, in frames: [WindowID: Rect]) -> WindowID? {
        guard let src = frames[from] else { return nil }
        let c = src.center
        var best: (WindowID, Double)?
        for (id, r) in frames where id != from {
            let o = r.center
            let along = direction.axis == .horizontal ? (o.x - c.x) * direction.sign : (o.y - c.y) * direction.sign
            guard along > 1 else { continue }
            let overlaps = direction.axis == .horizontal
                ? r.minY < src.maxY && r.maxY > src.minY
                : r.minX < src.maxX && r.maxX > src.minX
            let across = direction.axis == .horizontal ? abs(o.y - c.y) : abs(o.x - c.x)
            let score = (overlaps ? 0 : 100_000) + along + across * 0.5
            if best == nil || score < best!.1 || (score == best!.1 && id < best!.0) { best = (id, score) }
        }
        return best?.0
    }
}
