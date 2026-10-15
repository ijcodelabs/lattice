/// Hint mode (Vimium-style): letter labels over every visible window; typing a label picks that window.

public struct HintTarget: Hashable, Codable, Sendable {
    public var window: WindowID
    public var frame: Rect
    public init(window: WindowID, frame: Rect) { self.window = window; self.frame = frame }
}

/// What the UI draws for one hint.
public struct HintBadge: Hashable, Codable, Sendable {
    public var label: String
    /// Letters already typed (a prefix of `label`).
    public var typed: String
    /// The window the badge sits on (AX coordinates).
    public var frame: Rect
    public init(label: String, typed: String, frame: Rect) { self.label = label; self.typed = typed; self.frame = frame }
}

public enum Hints {
    /// Home row first, the most comfortable keys first.
    public static let alphabet: [Character] = ["a", "s", "d", "f", "j", "k", "l", "g", "h"]

    /// `count` labels, prefix-free: single letters while they suffice, otherwise all two-letter labels.
    public static func labels(count: Int) -> [String] {
        guard count > 0 else { return [] }
        if count <= alphabet.count { return alphabet.prefix(count).map(String.init) }
        var out: [String] = []
        for a in alphabet { for b in alphabet { out.append("\(a)\(b)") } }
        return Array(out.prefix(count))
    }
}

public struct HintState: Hashable, Sendable {
    public var action: HintAction
    public var targets: [String: HintTarget]
    public var typed = ""

    public init(action: HintAction, targets: [HintTarget]) {
        self.action = action
        self.targets = Dictionary(uniqueKeysWithValues: zip(Hints.labels(count: targets.count), targets).map { ($0, $1) })
    }

    public var badges: [HintBadge] {
        targets.filter { $0.key.hasPrefix(typed) }.sorted { $0.key < $1.key }
            .map { HintBadge(label: $0.key, typed: typed, frame: $0.value.frame) }
    }
}
