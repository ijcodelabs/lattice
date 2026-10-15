/// Multi-display helpers: picking displays by selector (config) or by target (commands).

/// Which display a workspace is pinned to (config `workspace-displays:`).
public enum DisplaySelector: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The primary display (menu bar).
    case main
    /// The first display that isn't the primary.
    case secondary
    /// 1-based, displays ordered left → right (then top → bottom).
    case index(Int)
    /// Case-insensitive substring of the display's name, e.g. "DELL".
    case name(String)

    public static func parse(_ text: String) -> DisplaySelector {
        switch text.lowercased() {
        case "main", "primary": return .main
        case "secondary": return .secondary
        default: return Int(text).map(DisplaySelector.index) ?? .name(text)
        }
    }

    public func resolve(in displays: [Display]) -> Display? {
        let ordered = Display.ordered(displays)
        switch self {
        case .main: return displays.first(where: \.isPrimary) ?? ordered.first
        case .secondary: return ordered.first { !$0.isPrimary }
        case let .index(i): return ordered.indices.contains(i - 1) ? ordered[i - 1] : nil
        case let .name(n): return ordered.first { $0.name.lowercased().contains(n.lowercased()) }
        }
    }

    public var description: String {
        switch self {
        case .main: "main"
        case .secondary: "secondary"
        case let .index(i): String(i)
        case let .name(n): n
        }
    }
}

/// Where a display command points.
public enum DisplayTarget: Hashable, Codable, Sendable, CustomStringConvertible {
    case direction(Direction)
    case next
    case prev

    public static func parse(_ text: String) -> DisplayTarget? {
        switch text.lowercased() {
        case "next": .next
        case "prev", "previous": .prev
        default: Direction(rawValue: text.lowercased()).map(DisplayTarget.direction)
        }
    }

    public var description: String {
        switch self {
        case let .direction(d): d.rawValue
        case .next: "next"
        case .prev: "prev"
        }
    }

    /// The display this target names, seen from `from`. Nil when there is none (single display, edge).
    public func resolve(from: Display, in displays: [Display]) -> Display? {
        let ordered = Display.ordered(displays)
        guard ordered.count > 1, let i = ordered.firstIndex(where: { $0.id == from.id }) else { return nil }
        switch self {
        case .next: return ordered[(i + 1) % ordered.count]
        case .prev: return ordered[(i - 1 + ordered.count) % ordered.count]
        case let .direction(d):
            // A display is "to the right" only if it lies beyond the right edge — not merely because its centre
            // is a little to the right (a laptop *below* an ultrawide must not count as left/right).
            let f = from.frame
            func beyond(_ t: Rect) -> Bool {
                switch d {
                case .right: t.minX >= f.maxX - 1
                case .left: t.maxX <= f.minX + 1
                case .down: t.minY >= f.maxY - 1
                case .up: t.maxY <= f.minY + 1
                }
            }
            func overlap(_ t: Rect) -> Double {
                d.axis == .horizontal ? min(f.maxY, t.maxY) - max(f.minY, t.minY) : min(f.maxX, t.maxX) - max(f.minX, t.minX)
            }
            func gap(_ t: Rect) -> Double {
                switch d {
                case .right: t.minX - f.maxX
                case .left: f.minX - t.maxX
                case .down: t.minY - f.maxY
                case .up: f.minY - t.maxY
                }
            }
            return displays
                .filter { $0.id != from.id && beyond($0.frame) }
                .min { a, b in
                    let (oa, ob) = (overlap(a.frame) > 0, overlap(b.frame) > 0)
                    return oa != ob ? oa : (gap(a.frame), a.id) < (gap(b.frame), b.id)
                }
        }
    }
}

extension Display {
    /// Left → right, then top → bottom: the order behind `next`/`prev` and `index` selectors.
    public static func ordered(_ displays: [Display]) -> [Display] {
        displays.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }
    }
}
