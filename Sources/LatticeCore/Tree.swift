/// i3-style layout tree. The root is always a split; leaves are windows.
/// Value type: every operation returns or mutates a plain struct — trivially testable.
public indirect enum TreeNode: Hashable, Codable, Sendable {
    case leaf(WindowID)
    case split(Split)

    public var leaves: [WindowID] {
        switch self {
        case let .leaf(id): [id]
        case let .split(s): s.children.flatMap(\.leaves)
        }
    }
}

public struct Split: Hashable, Codable, Sendable {
    public var orientation: Orientation
    public var children: [TreeNode]
    /// Relative sizes, same count as `children`.
    public var weights: [Double]

    public init(orientation: Orientation, children: [TreeNode] = [], weights: [Double]? = nil) {
        self.orientation = orientation
        self.children = children
        self.weights = weights ?? Array(repeating: 1, count: children.count)
    }
}

public struct LayoutTree: Hashable, Codable, Sendable {
    public var root: Split

    public init(orientation: Orientation = .horizontal) { root = Split(orientation: orientation) }
    public init(root: Split) { self.root = root }

    /// Flat tree from an ordered window list (used when a workspace first switches to `.tree`).
    public init(windows: [WindowID], orientation: Orientation = .horizontal) {
        root = Split(orientation: orientation, children: windows.map(TreeNode.leaf))
    }

    public var leaves: [WindowID] { root.children.flatMap(\.leaves) }
    public func contains(_ id: WindowID) -> Bool { path(to: id) != nil }

    // MARK: - Paths

    /// Child indices from the root to the leaf.
    func path(to id: WindowID) -> [Int]? {
        func search(_ split: Split, _ prefix: [Int]) -> [Int]? {
            for (i, child) in split.children.enumerated() {
                switch child {
                case let .leaf(leaf) where leaf == id: return prefix + [i]
                case let .split(s): if let p = search(s, prefix + [i]) { return p }
                default: continue
                }
            }
            return nil
        }
        return search(root, [])
    }

    /// Mutate the split at `path` (empty path = root).
    mutating func withSplit(at path: ArraySlice<Int>, _ body: (inout Split) -> Void) {
        func go(_ split: inout Split, _ path: ArraySlice<Int>) {
            guard let first = path.first else { body(&split); return }
            guard case var .split(child) = split.children[first] else { return }
            go(&child, path.dropFirst())
            split.children[first] = .split(child)
        }
        go(&root, path)
    }

    func split(at path: ArraySlice<Int>) -> Split? {
        var current = root
        for i in path {
            guard current.children.indices.contains(i), case let .split(s) = current.children[i] else { return nil }
            current = s
        }
        return current
    }

    // MARK: - Operations

    /// Insert `id` right after `target` in target's parent split (or append to the root).
    public mutating func insert(_ id: WindowID, after target: WindowID?) {
        guard !contains(id) else { return }
        guard let target, let p = path(to: target) else {
            root.children.append(.leaf(id))
            root.weights.append(root.weights.isEmpty ? 1 : root.weights.reduce(0, +) / Double(root.weights.count))
            return
        }
        withSplit(at: p.dropLast()) { s in
            let i = p.last! + 1
            let w = s.weights.reduce(0, +) / Double(max(1, s.weights.count))
            s.children.insert(.leaf(id), at: i)
            s.weights.insert(w, at: i)
        }
    }

    public mutating func remove(_ id: WindowID) {
        guard let p = path(to: id) else { return }
        withSplit(at: p.dropLast()) { s in
            s.children.remove(at: p.last!)
            s.weights.remove(at: p.last!)
        }
        normalize()
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let pa = path(to: a), let pb = path(to: b) else { return }
        withSplit(at: pa.dropLast()) { $0.children[pa.last!] = .leaf(b) }
        withSplit(at: pb.dropLast()) { $0.children[pb.last!] = .leaf(a) }
    }

    /// Replace leaf `old` with `new` in place (a window becoming a group's tile, or back).
    public mutating func rename(_ old: WindowID, to new: WindowID) {
        guard let p = path(to: old), !contains(new) else { return }
        withSplit(at: p.dropLast()) { $0.children[p.last!] = .leaf(new) }
    }

    /// i3 `split h|v`: the next window opened next to `id` goes in this orientation.
    /// A lone child just re-orients its parent; otherwise the leaf is wrapped in a new split.
    public mutating func split(_ id: WindowID, _ orientation: Orientation) {
        guard let p = path(to: id) else { return }
        withSplit(at: p.dropLast()) { s in
            if s.children.count == 1 {
                s.orientation = orientation
            } else {
                s.children[p.last!] = .split(Split(orientation: orientation, children: [.leaf(id)]))
            }
        }
    }

    /// Grow (`delta` > 0) or shrink `id` along `axis` by taking weight from its neighbour in the nearest
    /// ancestor split with that orientation. Each child keeps at least 10% of its split.
    /// `fromBefore`: take/give space from the sibling *before* (left/above) instead of after — used when the
    /// user dragged the leading edge with the mouse.
    public mutating func resize(_ id: WindowID, axis: Orientation, delta: Double, fromBefore: Bool = false) {
        guard let p = path(to: id) else { return }
        for depth in stride(from: p.count - 1, through: 0, by: -1) {
            let parentPath = p.prefix(depth)
            guard let s = split(at: parentPath), s.orientation == axis, s.children.count > 1 else { continue }
            let i = p[depth]
            let after = i + 1 < s.children.count ? i + 1 : nil, before = i > 0 ? i - 1 : nil
            guard let j = fromBefore ? (before ?? after) : (after ?? before) else { continue }
            withSplit(at: parentPath) { s in
                let total = s.weights.reduce(0, +)
                let minW = total * 0.1
                let amount = delta * total
                let give = min(max(amount, -(s.weights[i] - minW)), s.weights[j] - minW)
                s.weights[i] += give
                s.weights[j] -= give
            }
            return
        }
    }

    public mutating func balance() {
        func go(_ s: inout Split) {
            s.weights = Array(repeating: 1, count: s.children.count)
            for i in s.children.indices {
                if case var .split(child) = s.children[i] { go(&child); s.children[i] = .split(child) }
            }
        }
        go(&root)
    }

    /// Drop empty splits and collapse single-child splits into their parent.
    mutating func normalize() {
        func clean(_ s: Split) -> TreeNode? {
            var out = Split(orientation: s.orientation)
            for (child, w) in zip(s.children, s.weights) {
                switch child {
                case .leaf: out.children.append(child); out.weights.append(w)
                case let .split(inner):
                    guard let c = clean(inner) else { continue }
                    out.children.append(c); out.weights.append(w)
                }
            }
            if out.children.isEmpty { return nil }
            if out.children.count == 1 { return out.children[0] }
            return .split(out)
        }
        switch clean(root) {
        case nil: root = Split(orientation: root.orientation)
        case let .leaf(id)?: root = Split(orientation: root.orientation, children: [.leaf(id)])
        case let .split(s)?: root = s
        }
    }

    // MARK: - Geometry

    public func frames(in area: Rect) -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        func go(_ s: Split, _ r: Rect) {
            let total = s.weights.reduce(0, +)
            guard total > 0 else { return }
            var offset = 0.0
            for (child, w) in zip(s.children, s.weights) {
                let share = w / total
                let piece: Rect = s.orientation == .horizontal
                    ? Rect(x: r.minX + offset * r.width, y: r.minY, width: share * r.width, height: r.height)
                    : Rect(x: r.minX, y: r.minY + offset * r.height, width: r.width, height: share * r.height)
                offset += share
                switch child {
                case let .leaf(id): out[id] = piece
                case let .split(inner): go(inner, piece)
                }
            }
        }
        go(root, area)
        return out
    }
}
