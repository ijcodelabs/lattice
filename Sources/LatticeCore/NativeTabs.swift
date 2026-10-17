/// macOS native tabs (Ghostty, Finder, TextEdit, Terminal…): every tab is its own window, but the app lists
/// only the *selected* tab's window; the others become hidden, unlisted windows that still exist. Lattice
/// tiles one slot per tab bar: a window that appears with a tab bar takes the slot of its sibling tab, and
/// hidden sibling tabs are forgotten (they come back the same way when selected). memory/gotchas.md #40.
public enum NativeTabs {
    /// Known windows that are hidden background tabs of `window`: same app, not listed by the app right now,
    /// and either named in its tab bar or sitting exactly where its tab group is. Best match first.
    public static func backgroundTabs(of window: WindowSnapshot, known: [WindowSnapshot], listed: Set<WindowID>,
                                      frames: [WindowID: Rect]) -> [WindowID] {
        guard window.tabs.count >= 2 else { return [] }
        let titles = Set(window.tabs)
        func close(_ r: Rect?) -> Bool {
            guard let r else { return false }
            return abs(r.minX - window.frame.minX) < 8 && abs(r.minY - window.frame.minY) < 8
                && abs(r.width - window.frame.width) < 8 && abs(r.height - window.frame.height) < 8
        }
        let candidates = known.filter { $0.pid == window.pid && $0.id != window.id && !listed.contains($0.id) }
            .filter { titles.contains($0.title) || close(frames[$0.id] ?? $0.frame) }
        // Same frame as the tab group first (the tab that was just showing), then by id for determinism.
        return candidates.sorted {
            let a = close(frames[$0.id] ?? $0.frame), b = close(frames[$1.id] ?? $1.frame)
            return a != b ? a : $0.id < $1.id
        }.map(\.id)
    }

    /// The events for one listed window: a new window takes its background tab's slot; extra (or, for a window
    /// we already manage, all) background tabs are dropped.
    public static func events(for window: WindowSnapshot, isKnown: Bool, known: [WindowSnapshot], listed: Set<WindowID>,
                              frames: [WindowID: Rect]) -> [Event] {
        var tabs = backgroundTabs(of: window, known: known, listed: listed, frames: frames)
        var events: [Event] = []
        if !isKnown {
            if tabs.isEmpty { return [.windowAdded(window)] }
            events.append(.windowReplaced(tabs.removeFirst(), with: window))
        }
        return events + tabs.map(Event.windowRemoved)
    }
}
