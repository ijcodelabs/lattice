/// Command palette: what can be chosen, and fuzzy ranking.
public enum Palette {
    /// Everything the palette offers for the current engine state: windows first, then workspaces,
    /// layouts and commands.
    public static func items(for engine: Engine) -> [PaletteItem] {
        var out: [PaletteItem] = []
        let order = engine.settings.workspaces + engine.workspaces.keys.sorted().filter { !engine.settings.workspaces.contains($0) }
        for wsName in order {
            guard let ws = engine.workspaces[wsName] else { continue }
            for id in ws.windows {
                guard let w = engine.windows[id] else { continue }
                let title = w.title.isEmpty ? w.app : "\(w.app) — \(w.title)"
                let grouped = ws.group(of: id) != nil ? " · group" : ""
                out.append(PaletteItem(id: "w:\(id.raw)", kind: .window, title: title,
                                       subtitle: "workspace \(wsName)\(grouped)\(id == engine.focused ? " · focused" : "")",
                                       command: Command.focusWindow(id).description))
            }
        }
        for wsName in order {
            let count = engine.workspaces[wsName]?.windows.count ?? 0
            out.append(PaletteItem(id: "ws:\(wsName)", kind: .workspace, title: "Workspace \(wsName)",
                                   subtitle: wsName == engine.active ? "current" : (count == 0 ? "empty" : count == 1 ? "1 window" : "\(count) windows"),
                                   command: Command.workspace(wsName).description))
        }
        for kind in LayoutKind.allCases {
            out.append(PaletteItem(id: "l:\(kind.rawValue)", kind: .layout, title: "Layout: \(kind.rawValue)",
                                   subtitle: kind == engine.activeWorkspace.layout ? "current" : "",
                                   command: Command.layout(kind).description))
        }
        let commands: [(Command, String)] = [
            (.toggleFloating, "Toggle floating"), (.balance, "Balance sizes"),
            (.split(.horizontal), "Split horizontal (tree)"), (.split(.vertical), "Split vertical (tree)"),
            (.workspaceBackAndForth, "Previous workspace"), (.retile, "Retile all windows"),
            (.reload, "Reload config"), (.quit, "Quit Lattice"),
        ]
        for (c, title) in commands {
            out.append(PaletteItem(id: "c:\(c.description)", kind: .command, title: title, subtitle: c.description,
                                   command: c.description))
        }
        return out
    }

    /// Items matching `query`, best first. Empty query keeps the original order.
    public static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let q = query.trimmingCharactersInWhitespace()
        guard !q.isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item -> (PaletteItem, Int, Int)? in
                // Title matches rank above subtitle-only matches.
                let scores = [Fuzzy.score(q, item.title), Fuzzy.score(q, item.subtitle).map { $0 - 20 }].compactMap { $0 }
                return scores.max().map { (item, $0, i) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }
}

/// Subsequence fuzzy matching with bonuses for word starts and consecutive runs (fzf-ish, tiny).
public enum Fuzzy {
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, run = 0, last = -2
        for (i, ch) in t.enumerated() where qi < q.count {
            guard ch == q[qi] else { run = 0; continue }
            var s = 1
            let boundary = i == 0 || !t[i - 1].isLetter && !t[i - 1].isNumber
            if boundary { s += 8 }
            if last == i - 1 { run += 1; s += 4 * run } else { run = 0 }
            if i == 0 { s += 4 }
            score += s
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - t.count / 8   // shorter texts win ties
    }
}

extension String {
    func trimmingCharactersInWhitespace() -> String {
        var s = Substring(self)
        while s.first?.isWhitespace == true { s = s.dropFirst() }
        while s.last?.isWhitespace == true { s = s.dropLast() }
        return String(s)
    }
}
