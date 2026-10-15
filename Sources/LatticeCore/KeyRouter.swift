/// Which-key routing as a pure state machine.
///
/// Normal state: global bindings; `mode X` enters mode X, anything unbound passes through to the app.
/// In a mode: the mode's keys apply; Escape exits; a global binding still works (and exits the mode);
/// any other key exits the mode and is swallowed — so a half-remembered sequence never types into an app.
public struct KeyRouter: Hashable, Sendable {
    public private(set) var mode: String?
    private var lastActivity: Double = 0
    /// Hint mode: labels on windows, keys pick one. Takes precedence over everything else.
    public private(set) var hint: HintState?

    public init() {}

    public struct Result: Hashable, Sendable {
        /// Swallow the key (true) or let the focused app receive it.
        public var consumed: Bool
        /// Commands for the engine (never `.mode` / `.modeExit` — those are handled here).
        public var commands: [Command]
        public var modeChanged: Bool

        static let pass = Result(consumed: false, commands: [], modeChanged: false)
    }

    public static let escape = KeyChord(modifiers: [], key: "escape")

    /// Enter hint mode (leaves any key mode).
    public mutating func startHints(_ action: HintAction, _ targets: [HintTarget]) {
        mode = nil
        hint = targets.isEmpty ? nil : HintState(action: action, targets: targets)
    }

    public mutating func handle(_ chord: KeyChord, settings: Settings, now: Double) -> Result {
        _ = expire(settings: settings, now: now)
        lastActivity = now

        if var h = hint {
            // Letters narrow the labels; a full label picks; Esc or any other key cancels (swallowed).
            guard chord.modifiers.isSubset(of: [.shift]), chord.key.count == 1, chord != Self.escape else {
                hint = nil
                return Result(consumed: true, commands: [], modeChanged: true)
            }
            h.typed += chord.key
            if let t = h.targets[h.typed] {
                hint = nil
                let cmd: Command = h.action == .focus ? .focusWindow(t.window) : .swapWindow(t.window)
                return Result(consumed: true, commands: [cmd], modeChanged: true)
            }
            hint = h.targets.keys.contains { $0.hasPrefix(h.typed) } ? h : nil
            return Result(consumed: true, commands: [], modeChanged: true)
        }

        guard let current = mode, let keymap = settings.modes[current] else {
            mode = nil
            guard let b = settings.bindings.first(where: { $0.chord == chord }) else { return .pass }
            return apply(b.command, settings: settings, sticky: false, wasInMode: false)
        }

        if chord == Self.escape {
            mode = nil
            return Result(consumed: true, commands: [], modeChanged: true)
        }
        if let b = keymap.bindings.first(where: { $0.chord == chord }) {
            return apply(b.command, settings: settings, sticky: keymap.sticky, wasInMode: true)
        }
        // A global chord still works from inside a mode.
        if let b = settings.bindings.first(where: { $0.chord == chord }) {
            mode = nil
            var r = apply(b.command, settings: settings, sticky: false, wasInMode: false)
            r.modeChanged = true
            return r
        }
        mode = nil
        return Result(consumed: true, commands: [], modeChanged: true)
    }

    private mutating func apply(_ command: Command, settings: Settings, sticky: Bool, wasInMode: Bool) -> Result {
        switch command {
        case let .mode(name):
            guard settings.modes[name] != nil else { return Result(consumed: true, commands: [], modeChanged: false) }
            mode = name
            return Result(consumed: true, commands: [], modeChanged: true)
        case .modeExit:
            let changed = mode != nil
            mode = nil
            return Result(consumed: true, commands: [], modeChanged: changed)
        default:
            if wasInMode && !sticky {
                mode = nil
                return Result(consumed: true, commands: [command], modeChanged: true)
            }
            return Result(consumed: true, commands: [command], modeChanged: false)
        }
    }

    /// Leave the mode after its inactivity timeout. Returns true when it just expired.
    public mutating func expire(settings: Settings, now: Double) -> Bool {
        guard let current = mode else { return false }
        let timeout = settings.modes[current]?.timeout ?? 0
        guard timeout > 0, now - lastActivity >= timeout else { return false }
        mode = nil
        return true
    }

    public mutating func reset() { mode = nil; hint = nil }

    /// What the which-key HUD should show for the current mode (nil = hide).
    public func hud(settings: Settings) -> HUDModel? {
        guard let current = mode, let keymap = settings.modes[current] else { return nil }
        let items = keymap.bindings.map { b -> HUDItem in
            if case let .mode(target) = b.command {
                let title = b.label ?? settings.modes[target]?.label ?? target
                return HUDItem(key: b.chord.symbol, label: title, isMode: true)
            }
            return HUDItem(key: b.chord.symbol, label: b.displayLabel, isMode: false)
        }
        return HUDModel(title: keymap.label ?? current, items: Self.foldNumberRuns(items), sticky: keymap.sticky)
    }

    /// `1 tab 1`, `2 tab 2`, … `9 tab 9` → one row `1–9  tab 1–9` (same for `workspace 1…9`).
    /// A run is ≥3 consecutive digit keys whose labels are the same text ending in that digit.
    static func foldNumberRuns(_ items: [HUDItem]) -> [HUDItem] {
        func split(_ item: HUDItem) -> (n: Int, prefix: String)? {
            guard item.key.count == 1, let n = Int(item.key), !item.isMode, item.label.hasSuffix(item.key) else { return nil }
            return (n, String(item.label.dropLast(item.key.count)))
        }
        var out: [HUDItem] = []
        var i = 0
        while i < items.count {
            guard let first = split(items[i]) else { out.append(items[i]); i += 1; continue }
            var j = i + 1
            while j < items.count, let next = split(items[j]), next.prefix == first.prefix, next.n == first.n + (j - i) { j += 1 }
            if j - i >= 3 {
                let last = first.n + (j - i) - 1
                out.append(HUDItem(key: "\(first.n)–\(last)", label: "\(first.prefix)\(first.n)–\(last)", isMode: false))
            } else {
                out.append(contentsOf: items[i..<j])
            }
            i = j
        }
        return out
    }
}
