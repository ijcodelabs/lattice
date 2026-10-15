/// The pure heart of Lattice: events in → state change → effects out. No AX, no clocks, no I/O.
/// The controller feeds it events from the AX edge and hotkeys, and executes the effects it returns.

public enum Event: Hashable, Sendable {
    case windowAdded(WindowSnapshot)
    case windowRemoved(WindowID)
    /// The OS reports a new focused window (click, Cmd-Tab, app launch…).
    case windowFocused(WindowID)
    case windowFrameObserved(WindowID, Rect)
    case displaysChanged([Display])
    case settingsChanged(Settings)
    case command(Command)
    /// Start rebuilding a saved layout from the windows that are (or will be) present, until `until`.
    case restoreSession(SessionSnapshot, until: Double)
    /// The user finished dragging a window with the mouse: its frame now, where the pointer was released,
    /// and whether the main modifier was held (→ float it there).
    case windowDragged(WindowID, frame: Rect, cursor: Point, float: Bool)
}

public enum Effect: Hashable, Sendable {
    case setFrame(WindowID, Rect)
    case focus(WindowID)
    case exec(String)
    case reload
    case quit
    case openPalette
    case log(String)
    /// Show hint labels on these windows (in reading order); the router takes the keys from here.
    case startHints(HintAction, [HintTarget])
    /// Write the session snapshot now.
    case saveSession
    /// Read the saved session and restore it (the controller answers with `.restoreSession`).
    case loadSession
    case forgetSession
}

public struct Engine: Sendable {
    public private(set) var settings: Settings
    public private(set) var displays: [Display]
    public private(set) var workspaces: [String: Workspace] = [:]
    /// The focused workspace (always visible on some display).
    public private(set) var active: String
    public private(set) var previous: String?
    /// Display → the workspace it shows. Every display shows one (when workspaces are available).
    public private(set) var visible: [UInt32: String] = [:]
    /// Workspace → the display it lives on (where it was last shown, or its pin).
    public private(set) var assigned: [String: UInt32] = [:]
    public private(set) var windows: [WindowID: WindowSnapshot] = [:]
    /// Window → workspace name.
    public private(set) var home: [WindowID: String] = [:]
    /// Last frame we asked for, per window (the diff baseline).
    public private(set) var sent: [WindowID: Rect] = [:]
    /// Last frame the OS reported, per window.
    public private(set) var observed: [WindowID: Rect] = [:]
    /// Parked windows → their last on-screen frame. The controller persists this as the rescue journal.
    public private(set) var parked: [WindowID: Rect] = [:]
    /// Time of our last workspace switch; OS focus events just after it are echoes, not user intent.
    private var lastSwitch: Double = -.infinity
    /// Next group id (`group:N`); ids are never reused.
    private var groupCounter = 0
    /// A session being restored (windows still coming back), its deadline, and the last window→slot match.
    public private(set) var restoring: SessionSnapshot?
    private var restoreUntil: Double = 0
    private var restoreMatch: [WindowID: WindowID] = [:]
    public static let switchEchoWindow = 0.4

    public init(settings: Settings, displays: [Display]) {
        self.settings = settings
        self.displays = displays
        self.active = settings.workspaces.first ?? "1"
        ensureWorkspace(active)
        syncDisplays()
    }

    // MARK: - Queries

    public var activeWorkspace: Workspace { workspaces[active]! }
    public var focused: WindowID? { activeWorkspace.focused }

    public var primary: Display {
        displays.first(where: \.isPrimary) ?? displays.first
            ?? Display(id: 0, name: "?", frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                       visibleFrame: Rect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
    }

    /// The display a workspace lives on (primary when unassigned or its display is gone).
    public func display(of workspace: String) -> Display {
        assigned[workspace].flatMap { id in displays.first { $0.id == id } } ?? primary
    }

    public var focusedDisplay: Display { display(of: active) }
    public func isVisible(_ workspace: String) -> Bool { visible.values.contains(workspace) }

    /// Visible workspaces, ordered by their display (left → right).
    public var visibleWorkspaces: [String] { Display.ordered(displays).compactMap { visible[$0.id] } }

    /// Tiling area of a workspace: its display's visible area minus a reserving bar.
    public func area(of workspace: String) -> Rect { settings.bar.tilingArea(in: display(of: workspace).visibleFrame) }

    /// Focused display's visible area (minus menu bar/Dock).
    public var visibleArea: Rect { focusedDisplay.visibleFrame }
    public var area: Rect { area(of: active) }

    /// Where the focused display's bar goes (nil when disabled).
    public var barFrame: Rect? { settings.bar.enabled ? settings.bar.frame(in: visibleArea) : nil }

    /// One bar per display.
    public var bars: [BarModel] {
        guard settings.bar.enabled else { return [] }
        return Display.ordered(displays).map {
            BarModel(displayID: $0.id, frame: settings.bar.frame(in: $0.visibleFrame), settings: settings.bar)
        }
    }

    /// Frame for the focus border: what the focused window really has (observed) when it is on screen,
    /// else what we asked for. Nil when nothing visible is focused.
    public var focusBorderFrame: Rect? {
        guard settings.borders.enabled, let f = focused, home[f] == active else { return nil }
        return observed[f] ?? sent[f]
    }

    /// Layout frame of each tile (window or group id) of one workspace.
    public func tileFrames(of name: String) -> [WindowID: Rect] {
        guard let ws = workspaces[name] else { return [:] }
        return Layout.frames(kind: ws.layout, tree: ws.tree, order: ws.order, focused: ws.focused.flatMap { ws.tile(of: $0) },
                             area: area(of: name), ratio: ws.ratio, gaps: settings.gaps)
    }

    /// Height of a group's tab strip inside its tile.
    func stripHeight(_ grp: WindowGroup, in tile: Rect) -> Double {
        guard settings.groups.tabBar else { return 0 }
        let rows = grp.style == .stacked ? Double(grp.members.count) : 1
        return min(settings.groups.tabHeight * rows, tile.height / 2)
    }

    /// On-screen frames of one workspace's windows: tiles laid out, a group's tile given to its shown member
    /// (minus the tab strip), plus floating windows unless `tiledOnly`. Hidden group members are absent.
    public func frames(of name: String, tiledOnly: Bool = false) -> [WindowID: Rect] {
        guard let ws = workspaces[name] else { return [:] }
        var out: [WindowID: Rect] = [:]
        for (tile, r) in tileFrames(of: name) {
            if let grp = ws.groups[tile] {
                let h = stripHeight(grp, in: r)
                out[grp.active] = Rect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
            } else {
                out[tile] = r
            }
        }
        if !tiledOnly { for (id, r) in ws.floating { out[id] = r } }
        return out
    }

    /// Tab strips of the groups on screen (for the UI).
    public var groupStrips: [GroupStrip] {
        guard settings.groups.tabBar else { return [] }
        var out: [GroupStrip] = []
        for name in visibleWorkspaces {
            guard let ws = workspaces[name] else { continue }
            for (tile, r) in tileFrames(of: name).sorted(by: { $0.key < $1.key }) {
                guard let grp = ws.groups[tile] else { continue }
                let tabs = grp.members.map { m in
                    GroupStrip.Tab(window: m.raw, app: windows[m]?.app ?? "?", title: windows[m]?.title ?? "", active: m == grp.active)
                }
                out.append(GroupStrip(id: tile.raw, frame: Rect(x: r.minX, y: r.minY, width: r.width, height: stripHeight(grp, in: r)),
                                      style: grp.style, focused: name == active && ws.focused.map(grp.members.contains) == true,
                                      tabs: tabs))
            }
        }
        return out
    }

    /// Frames of everything on screen: every visible workspace, on every display.
    public func visibleFrames(tiledOnly: Bool = false) -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        for name in visibleWorkspaces { out.merge(frames(of: name, tiledOnly: tiledOnly)) { a, _ in a } }
        return out
    }

    // MARK: - Reduce

    /// Apply events, then return the effects: frame changes first (diffed against what we already sent),
    /// then focus/exec/etc. `now` is seconds on any monotonic clock.
    public mutating func handle(_ events: [Event], now: Double) -> [Effect] {
        var intents: [Effect] = []
        for e in events { intents += apply(e, now: now) }
        if restoring != nil { intents += progressRestore(now: now) }
        return layoutEffects() + intents
    }

    public mutating func handle(_ event: Event, now: Double) -> [Effect] { handle([event], now: now) }

    mutating func apply(_ event: Event, now: Double) -> [Effect] {
        switch event {
        case let .windowAdded(snap): return add(snap)
        case let .windowRemoved(id): return remove(id)
        case let .windowFocused(id): return osFocused(id, now: now)
        case let .windowFrameObserved(id, r): observe(id, r); return []
        case let .displaysChanged(d):
            displays = d
            syncDisplays()
            return [.log("displays: \(Display.ordered(d).map { "\($0.name) → \(visible[$0.id] ?? "-")" }.joined(separator: ", "))")]
        case let .settingsChanged(s): return applySettings(s)
        case let .command(c):
            if restoring != nil, Self.endsRestore(c) {
                restoring = nil
                return [.log("session restore stopped — you took over")] + run(c, now: now)
            }
            return run(c, now: now)
        case let .windowDragged(id, frame, cursor, float):
            if restoring != nil { restoring = nil }
            return dragged(id, frame: frame, cursor: cursor, float: float)
        case let .restoreSession(snap, until):
            restoring = snap
            restoreUntil = until
            restoreMatch = [:]
            return [.log("restoring session: \(snap.windows.count) window(s) in \(snap.workspaces.filter { !$0.windows.isEmpty }.count) workspace(s)")]
        }
    }

    // MARK: - Window lifecycle

    mutating func add(_ snap: WindowSnapshot) -> [Effect] {
        if windows[snap.id] != nil { windows[snap.id] = snap; return [] }
        windows[snap.id] = snap
        observed[snap.id] = snap.frame

        var float = false
        var target = active
        for rule in settings.rules where rule.matches(snap) {
            if let f = rule.float { float = f }
            if let w = rule.workspace { target = w }
        }
        ensureWorkspace(target)
        home[snap.id] = target
        let focusNew = settings.focusNewWindows
        update(target) { ws in
            if float { ws.floating[snap.id] = snap.frame } else { ws.addTiled(snap.id, after: ws.focused) }
            if focusNew || ws.focused == nil { ws.setFocused(snap.id) }
        }
        return []
    }

    mutating func remove(_ id: WindowID) -> [Effect] {
        let effects = detach(id)
        windows[id] = nil; home[id] = nil; sent[id] = nil; observed[id] = nil; parked[id] = nil
        return effects
    }

    /// Take a window out of its workspace (picking the next focus there) but keep tracking it.
    mutating func detach(_ id: WindowID) -> [Effect] {
        guard let wsName = home[id] else { return [] }
        var effects: [Effect] = []
        let isActive = wsName == active
        update(wsName) { ws in
            let tile = ws.tile(of: id)
            let index = tile.flatMap { ws.order.firstIndex(of: $0) }
            let group = ws.group(of: id)
            ws.remove(id)
            if ws.focused == id {
                let next: WindowID?
                if let group, let grp = ws.groups[group] {
                    next = grp.active                                   // stay in the group's slot
                } else if group != nil, let i = index, ws.order.indices.contains(i) {
                    next = ws.shown(ws.order[i])                         // group dissolved: its last member
                } else if let i = index, !ws.order.isEmpty {
                    next = ws.shown(ws.order[max(0, min(i, ws.order.count) - 1)])
                } else {
                    next = ws.windows.first
                }
                ws.setFocused(next)
                if isActive, let next { effects.append(.focus(next)) }
            }
        }
        return effects
    }

    mutating func osFocused(_ id: WindowID, now: Double) -> [Effect] {
        guard let wsName = home[id] else { return [] }
        // A hidden group member got focus. Right after we switched tabs that's an echo of the parking;
        // otherwise (Cmd-Tab, click in the palette…) the group follows it.
        if let ws = workspaces[wsName], let g = ws.group(of: id), ws.groups[g]?.active != id,
           now - lastSwitch <= Self.switchEchoWindow { return [] }
        if wsName != active {
            if isVisible(wsName) {
                // Clicked into another display: that workspace becomes the focused one.
                previous = active
                active = wsName
            } else {
                // Echo of our own parking right after a switch — ignore. Otherwise the user Cmd-Tabbed / clicked
                // into a hidden window: follow it to its workspace.
                guard now - lastSwitch > Self.switchEchoWindow else { return [] }
                switchTo(wsName, now: now)
            }
        }
        update(wsName) { $0.setFocused(id) }
        return []
    }

    mutating func observe(_ id: WindowID, _ r: Rect) {
        observed[id] = r
        guard let wsName = home[id], isVisible(wsName), workspaces[wsName]?.floating[id] != nil else { return }
        // Ignore the echo of our own move; otherwise the user dragged a floating window — remember it.
        if let s = sent[id], s.approximatelyEquals(r, tolerance: 2) { return }
        update(wsName) { $0.floating[id] = r }
        sent[id] = r
    }

    mutating func applySettings(_ s: Settings) -> [Effect] {
        settings = s
        for name in s.workspaces { ensureWorkspace(name) }
        syncDisplays()
        return [.log("settings applied")]
    }

    // MARK: - Commands

    mutating func run(_ command: Command, now: Double) -> [Effect] {
        switch command {
        case let .focus(d): return focus(d)
        case let .move(d): move(d); return []
        case let .workspace(name): return switchTo(name, now: now)
        case .workspaceBackAndForth: return previous.map { switchTo($0, now: now) } ?? []
        case .workspaceNext: return switchTo(cycledWorkspace(+1), now: now)
        case .workspacePrev: return switchTo(cycledWorkspace(-1), now: now)
        case let .moveToWorkspace(name, follow): return moveFocused(to: name, follow: follow, now: now)
        case let .layout(kind): setLayout(kind); return []
        case .layoutNext:
            let all = LayoutKind.allCases
            setLayout(all[(all.firstIndex(of: activeWorkspace.layout)! + 1) % all.count])
            return [.log("layout \(activeWorkspace.layout.rawValue)")]
        case let .split(o):
            if let f = focused, let t = activeWorkspace.tile(of: f) {
                let grouped = activeWorkspace.groups[t] != nil
                var effects: [Effect] = []
                // Splitting a specific window only makes sense in a tree. Dwindle and master are automatic
                // trees: turn this workspace into the identical tree (nothing moves), then split there.
                let ws0 = activeWorkspace
                if ws0.layout == .dwindle || ws0.layout == .master {
                    let tree = Layout.equivalentTree(kind: ws0.layout, order: ws0.order, area: area, ratio: ws0.ratio, gaps: settings.gaps)
                    update(active) { ws in ws.tree = tree; ws.layout = .tree }
                    effects.append(.log("layout → tree (same arrangement) so the split applies to this window"))
                }
                update(active) { ws in
                    ws.tree.split(t, o)
                    if grouped { ws.nextOutsideGroup = o }   // the next window goes next to the group, not into it
                }
                if grouped { effects.append(.log("next window opens \(o == .vertical ? "below" : "beside") the group")) }
                return effects
            }
            return []
        case .toggleFloating: toggleFloating(); return []
        case let .resize(grow, axis, amount): resize(grow ? amount : -amount, axis: axis); return []
        case .balance:
            let ratio = settings.ratio
            update(active) { ws in ws.tree.balance(); ws.ratio = ratio }
            return []
        case let .exec(cmd): return [.exec(cmd)]
        case .retile: sent.removeAll(); return []
        case .reload: return [.reload]
        case .quit: return [.quit]
        case .palette: return [.openPalette]
        case .mode, .modeExit: return []          // routed by KeyRouter before reaching the engine
        case let .focusWindow(id):
            guard let ws = home[id] else { return [] }
            if ws != active { switchTo(ws, now: now) }
            update(ws) { $0.setFocused(id) }
            lastSwitch = now
            return [.focus(id)]
        case let .focusDisplay(t):
            guard let d = t.resolve(from: focusedDisplay, in: displays) else { return [] }
            return focusDisplay(d)
        case let .moveToDisplay(t):
            guard let d = t.resolve(from: focusedDisplay, in: displays) else { return [] }
            return moveFocused(toDisplay: d)
        case let .moveWorkspaceToDisplay(t):
            guard let d = t.resolve(from: focusedDisplay, in: displays) else { return [] }
            return moveActiveWorkspace(to: d, now: now)
        case let .group(d): return group(d)
        case .ungroup: return ungroup()
        case let .groupCycle(step): return cycleGroup(step, now: now)
        case let .groupStyle(st): setGroupStyle(st); return []
        case let .groupMove(d): moveTab(d); return []
        case let .groupTab(n): return showTab(n, now: now)
        case let .hints(action):
            let targets = hintTargets(excludingFocused: action == .swap)
            return targets.isEmpty ? [] : [.startHints(action, targets)]
        case let .swapWindow(t): return swapFocused(with: t)
        case .session(.save): return [.saveSession]
        case .session(.restore): return [.loadSession]
        case .session(.forget): return [.forgetSession]
        }
    }

    /// Directional focus: the neighbour on this workspace; past the edge, the display that way (even if its
    /// workspace is empty); with neither, wrap to the far side of this workspace (`focus-wrap`).
    mutating func focus(_ d: Direction) -> [Effect] {
        let ws = activeWorkspace
        let displayThatWay = DisplayTarget.direction(d).resolve(from: focusedDisplay, in: displays)
        guard let f = ws.focused else {
            // Empty (or nothing focused) workspace: never a dead end.
            if let disp = displayThatWay { return focusDisplay(disp) }
            return ws.windows.first.map { id in update(active) { $0.setFocused(id) }; return [.focus(id)] } ?? []
        }
        let mine = frames(of: active)
        var target: WindowID?
        if ws.layout == .monocle, let t = ws.tile(of: f), let i = ws.order.firstIndex(of: t) {
            let step = d == .left || d == .up ? -1 : 1
            target = ws.order.count > 1 ? ws.shown(ws.order[(i + step + ws.order.count) % ws.order.count]) : nil
        } else {
            target = Layout.neighbour(of: f, d, in: mine)
            if target == nil {
                if let disp = displayThatWay { return focusDisplay(disp) }
                if settings.focusWrap { target = Layout.wrapTarget(from: f, d, in: mine) }
            }
        }
        guard let t = target else { return [] }
        update(active) { $0.setFocused(t) }
        return [.focus(t)]
    }

    /// Focus the workspace shown on `d` (and its focused window, if any).
    mutating func focusDisplay(_ d: Display) -> [Effect] {
        guard let ws = visible[d.id], ws != active else { return [] }
        previous = active
        active = ws
        guard let w = activeWorkspace.focused ?? activeWorkspace.windows.first else { return [.log("display \(d.name) (empty)")] }
        update(ws) { $0.setFocused(w) }
        return [.focus(w)]
    }

    mutating func move(_ d: Direction) {
        let ws = activeWorkspace
        guard let f = ws.focused else { return }
        if let r = ws.floating[f] {
            let step = 40.0
            var moved = r
            if d.axis == .horizontal { moved.origin.x += step * d.sign } else { moved.origin.y += step * d.sign }
            update(active) { $0.floating[f] = moved }
            return
        }
        guard let ft = ws.tile(of: f) else { return }
        let other: WindowID?
        if ws.layout == .monocle {
            let i = ws.order.firstIndex(of: ft)!
            let step = d == .left || d == .up ? -1 : 1
            other = ws.order.indices.contains(i + step) ? ws.shown(ws.order[i + step]) : nil
        } else {
            other = Layout.neighbour(of: f, d, in: frames(of: active, tiledOnly: true))
        }
        guard let o = other else {
            // Edge of this display: carry the window to the display beyond (even an empty one).
            if let disp = DisplayTarget.direction(d).resolve(from: focusedDisplay, in: displays) { _ = moveFocused(toDisplay: disp) }
            return
        }
        if let ows = home[o], ows != active {
            // The neighbour is on another display: the window joins that workspace, next to it.
            let from = active
            _ = detach(f)
            home[f] = ows
            update(ows) { ws in ws.addTiled(f, after: ws.tile(of: o)); ws.setFocused(f) }
            previous = from
            active = ows
            return
        }
        update(active) { ws in
            guard let ot = ws.tile(of: o), ot != ft else { return }
            let i = ws.order.firstIndex(of: ft)!, j = ws.order.firstIndex(of: ot)!
            ws.order.swapAt(i, j)
            ws.tree.swap(ft, ot)
        }
    }

    /// Show and focus a workspace. Already visible on some display → just focus it there. Otherwise it
    /// appears on its pinned display, else the display it was last on, else the focused display —
    /// replacing (parking) whatever that display showed.
    @discardableResult
    mutating func switchTo(_ name: String, now: Double) -> [Effect] {
        guard name != active else { return [] }
        ensureWorkspace(name)
        if !isVisible(name) {
            let target = pinnedDisplay(name)?.id
                ?? assigned[name].flatMap { id in displays.contains { $0.id == id } ? id : nil }
                ?? focusedDisplay.id
            visible[target] = name
            assigned[name] = target
            lastSwitch = now
        }
        previous = active
        active = name
        let ws = activeWorkspace
        guard let target = ws.focused ?? ws.windows.first else { return [.log("workspace \(name) (empty)")] }
        update(name) { $0.setFocused(target) }
        return [.focus(target)]
    }

    mutating func moveFocused(to name: String, follow: Bool, now: Double) -> [Effect] {
        guard let f = focused, name != active else { return [] }
        ensureWorkspace(name)
        let floatingFrame = activeWorkspace.floating[f]
        var effects: [Effect] = []
        let from = active
        _ = detach(f)          // picks the next focus on the old workspace
        home[f] = name
        update(name) { ws in
            if let r = floatingFrame { ws.floating[f] = r } else { ws.addTiled(f, after: ws.focused) }
            ws.setFocused(f)
        }
        if follow {
            effects += switchTo(name, now: now)
        } else if let next = workspaces[from]?.focused {
            effects.append(.focus(next))
        }
        return effects
    }

    /// Move the focused window onto the workspace shown on `d`, and follow it.
    mutating func moveFocused(toDisplay d: Display) -> [Effect] {
        guard let f = focused, let dest = visible[d.id], dest != active else { return [] }
        let from = focusedDisplay
        let floatingFrame = activeWorkspace.floating[f].map { Self.translate($0, from: from, to: d) }
        _ = detach(f)
        home[f] = dest
        update(dest) { ws in
            if let r = floatingFrame { ws.floating[f] = r } else { ws.addTiled(f, after: ws.focused) }
            ws.setFocused(f)
        }
        previous = active
        active = dest
        return [.focus(f)]
    }

    /// Move the focused workspace to display `d`; the display it leaves shows its next free workspace.
    mutating func moveActiveWorkspace(to d: Display, now: Double) -> [Effect] {
        let from = focusedDisplay
        guard d.id != from.id else { return [] }
        let name = active
        visible[from.id] = nil
        visible[d.id] = name
        assigned[name] = d.id
        update(name) { ws in
            for (id, r) in ws.floating { ws.floating[id] = Self.translate(r, from: from, to: d) }
        }
        lastSwitch = now
        syncDisplays()
        return activeWorkspace.focused.map { [.focus($0)] } ?? []
    }

    mutating func setLayout(_ kind: LayoutKind) {
        let fallback: LayoutKind = settings.defaultLayout == .monocle ? .dwindle : settings.defaultLayout
        update(active) { ws in
            var kind = kind
            // Monocle is "zoom": asking for it again goes back (i3's fullscreen toggle on mod+f).
            if kind == .monocle, ws.layout == .monocle { kind = ws.previousLayout ?? fallback }
            if kind != ws.layout { ws.previousLayout = ws.layout; ws.layout = kind }
            if kind == .tree, Set(ws.tree.leaves) != Set(ws.order) { ws.tree = LayoutTree(windows: ws.order) }
        }
    }

    mutating func toggleFloating() {
        guard let f = focused else { return }
        let a = area
        update(active) { ws in
            if ws.floating[f] != nil {
                ws.floating[f] = nil
                ws.insertTile(f, afterTile: ws.order.last)
            } else {
                ws.remove(f)
                let w = a.width * 0.6, h = a.height * 0.6
                ws.floating[f] = Rect(x: a.minX + (a.width - w) / 2, y: a.minY + (a.height - h) / 2, width: w, height: h)
            }
        }
    }

    mutating func resize(_ delta: Double, axis: Orientation?) {
        guard let f = focused else { return }
        let ws = activeWorkspace
        if let r = ws.floating[f] {
            let dw = area.width * delta, dh = area.height * delta
            let grown = Rect(x: r.minX - dw / 2, y: r.minY - dh / 2, width: max(100, r.width + dw), height: max(80, r.height + dh))
            update(active) { $0.floating[f] = grown }
            return
        }
        switch ws.layout {
        case .tree:
            guard let t = ws.tile(of: f) else { return }
            let parentAxis = axis ?? ws.tree.parentOrientation(of: t) ?? .horizontal
            update(active) { $0.tree.resize(t, axis: parentAxis, delta: delta) }
        case .dwindle, .master:
            let signed = ws.order.first == ws.tile(of: f) ? delta : -delta
            update(active) { $0.ratio = min(0.9, max(0.1, $0.ratio + signed)) }
        case .monocle:
            break
        }
    }

    // MARK: - Layout → effects

    /// Desired frame of every managed window: visible workspaces laid out on their displays, every other
    /// workspace parked in a corner of its own display.
    public func desiredFrames() -> [WindowID: Rect] {
        var out = visibleFrames()
        // Everything not on screen is parked on its workspace's display: windows of hidden workspaces and
        // hidden members of groups.
        for (name, ws) in workspaces {
            let home = display(of: name)
            for id in ws.windows where out[id] == nil {
                let size = (parked[id] ?? sent[id] ?? observed[id])?.size ?? Size(width: 800, height: 600)
                out[id] = Parking.plan(size: size, home: home, displays: displays)?.frame
                    ?? Parking.parkedFrame(size: size, display: home.frame, corner: .bottomRight, strategy: .sliver)
            }
        }
        return out
    }

    mutating func layoutEffects() -> [Effect] {
        let desired = desiredFrames()
        // Track parking: remember the last on-screen frame when a window leaves the screen
        // (its workspace hidden, or it became a hidden group member).
        let onScreen = Set(visibleFrames().keys)
        for id in home.keys {
            if onScreen.contains(id) {
                parked[id] = nil
            } else if parked[id] == nil {
                parked[id] = sent[id] ?? observed[id]
            }
        }
        var effects: [Effect] = []
        for id in desired.keys.sorted() {
            let r = desired[id]!
            if let s = sent[id], s.approximatelyEquals(r, tolerance: 1) { continue }
            sent[id] = r
            observed[id] = nil   // stale until the OS reports the new frame (the focus border uses `sent` meanwhile)
            effects.append(.setFrame(id, r))
        }
        return effects
    }

    /// Frames that put every parked window back on screen (shutdown / crash recovery).
    public func restoreEffects() -> [Effect] {
        parked.keys.sorted().compactMap { id in parked[id].map { .setFrame(id, $0) } }
    }

    // MARK: - Hints

    /// Every window on screen (all displays), in reading order: display by display (left → right), then
    /// top → bottom, left → right.
    public func hintTargets(excludingFocused: Bool) -> [HintTarget] {
        let frames = visibleFrames()
        let order = Dictionary(uniqueKeysWithValues: Display.ordered(displays).enumerated().map { ($1.id, $0) })
        return frames
            .filter { !excludingFocused || $0.key != focused }
            .map { (id: $0.key, frame: $0.value, d: order[display(of: home[$0.key] ?? active).id] ?? 0) }
            .sorted { ($0.d, ($0.frame.minY / 40).rounded(), $0.frame.minX, $0.id) < ($1.d, ($1.frame.minY / 40).rounded(), $1.frame.minX, $1.id) }
            .map { HintTarget(window: $0.id, frame: $0.frame) }
    }

    /// Swap the focused window with `t` — same workspace, or across workspaces/displays (each takes the
    /// other's place, groups and floating included). Focus stays on the window that moved.
    mutating func swapFocused(with t: WindowID) -> [Effect] {
        guard let f = focused, f != t, let fws = home[f], let tws = home[t] else { return [] }
        if fws == tws {
            update(fws) { ws in ws.rename([f: t, t: f]); ws.setFocused(f) }
        } else {
            update(fws) { $0.rename([f: t]) }
            update(tws) { ws in ws.rename([t: f]); ws.setFocused(f) }
            home[f] = tws
            home[t] = fws
            if workspaces[fws]?.focused == f { update(fws) { $0.setFocused(t) } }
            if isVisible(tws) { previous = active; active = tws }
        }
        sent[f] = nil
        sent[t] = nil
        return [.focus(f)]
    }

    // MARK: - Mouse

    /// A finished mouse drag of `id`. Tiled windows: dropped on another window → swap (or join that display's
    /// workspace); an edge dragged → resize the split; main modifier held → float where dropped; anything
    /// else snaps back. Floating windows simply keep their new frame.
    mutating func dragged(_ id: WindowID, frame: Rect, cursor: Point, float: Bool) -> [Effect] {
        guard let wsName = home[id], let ws = workspaces[wsName] else { return [] }
        if ws.floating[id] != nil {
            update(wsName) { $0.floating[id] = frame }
            sent[id] = frame
            return []
        }
        guard let old = sent[id] else { return [] }
        defer { sent[id] = nil }   // whatever happens, re-send this window's frame (snap into place)

        if float {
            update(wsName) { ws in
                ws.remove(id)
                ws.floating[id] = frame
                ws.setFocused(id)
            }
            return [.log("floated \(windows[id]?.app ?? "window") where it was dropped")]
        }

        let dw = frame.width - old.width, dh = frame.height - old.height
        // A resize keeps one horizontal AND one vertical edge in place (edge or corner drag). If both
        // left and right (or top and bottom) moved, it was a move — even if macOS also changed the size.
        let leftFixed = abs(frame.minX - old.minX) <= 8, rightFixed = abs(frame.maxX - old.maxX) <= 8
        let topFixed = abs(frame.minY - old.minY) <= 8, bottomFixed = abs(frame.maxY - old.maxY) <= 8
        if (abs(dw) > 8 || abs(dh) > 8), leftFixed || rightFixed, topFixed || bottomFixed {
            // An edge was dragged: grow/shrink along that axis, taking space from the side that moved.
            let axis: Orientation = abs(dw) >= abs(dh) ? .horizontal : .vertical
            let leading = axis == .horizontal
                ? abs(frame.minX - old.minX) > abs(frame.maxX - old.maxX)
                : abs(frame.minY - old.minY) > abs(frame.maxY - old.maxY)
            let a = area(of: wsName)
            let delta = axis == .horizontal ? dw / a.width : dh / a.height
            guard let t = ws.tile(of: id) else { return [] }
            switch ws.layout {
            case .tree:
                update(wsName) { $0.tree.resize(t, axis: axis, delta: delta, fromBefore: leading) }
            case .dwindle, .master:
                let first = ws.order.first == t
                update(wsName) { $0.ratio = min(0.9, max(0.1, $0.ratio + (first ? delta : -delta))) }
            case .monocle:
                break
            }
            for other in ws.windows { sent[other] = nil }   // neighbours snap to the new split too
            return []
        }

        // Moved: what is under the pointer?
        let targets = visibleFrames().filter { $0.key != id && $0.value.contains(cursor) }
        if let (t, _) = targets.min(by: { $0.value.area < $1.value.area }), let tws = home[t] {
            if tws == wsName {
                update(wsName) { ws in
                    let focused = ws.focused
                    ws.rename([id: t, t: id])          // swap the two windows' places (tiles or group slots)
                    ws.focused = focused
                }
                sent[t] = nil
                return [.log("swapped by drag")]
            }
            // Dropped onto a window on another display: join that workspace next to it.
            _ = detach(id)
            home[id] = tws
            update(tws) { ws in ws.insertTile(id, afterTile: ws.tile(of: t)); ws.setFocused(id) }
            previous = active
            active = tws
            return [.focus(id)]
        }
        // Dropped on an empty display: move there.
        if let d = displays.first(where: { $0.frame.contains(cursor) }), d.id != display(of: wsName).id,
           let dest = visible[d.id], workspaces[dest]?.windows.isEmpty ?? true {
            _ = detach(id)
            home[id] = dest
            update(dest) { ws in ws.insertTile(id, afterTile: ws.order.last); ws.setFocused(id) }
            previous = active
            active = dest
            return [.focus(id)]
        }
        return []   // nowhere useful: snap back (sent cleared above)
    }

    // MARK: - Session

    /// Commands that mean "the user is arranging things now": a running restore must not undo them.
    static func endsRestore(_ c: Command) -> Bool {
        switch c {
        case .palette, .mode, .modeExit, .reload, .session, .exec: false
        default: true
        }
    }

    /// Snapshot of the current layout for saving. Nil while a restore is still running (a half-restored
    /// layout must never overwrite the good one on disk).
    public func snapshot(savedAt: Double) -> SessionSnapshot? {
        guard restoring == nil else { return nil }
        let ords = SessionMatcher.ordinals(Array(windows.values))
        let saved = home.keys.sorted().compactMap { id -> SavedWindow? in
            guard let w = windows[id], let ws = home[id] else { return nil }
            let frame = workspaces[ws]?.floating[id] ?? parked[id] ?? sent[id] ?? observed[id] ?? w.frame
            return SavedWindow(slot: id, bundleID: w.bundleID, app: w.app, title: settings.session.saveTitles ? w.title : nil,
                               frame: frame, ordinal: ords[id] ?? 0, workspace: ws)
        }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.name) })
        return SessionSnapshot(
            savedAt: savedAt, active: active,
            visible: Dictionary(visible.compactMap { d, ws in byID[d].map { ($0, ws) } }, uniquingKeysWith: { a, _ in a }),
            assigned: Dictionary(uniqueKeysWithValues: assigned.compactMap { ws, d in byID[d].map { (ws, $0) } }),
            workspaces: workspaces.values.sorted { $0.name < $1.name }, windows: saved)
    }

    /// Re-match present windows to the saved slots; when the match changed, rebuild the saved layout.
    mutating func progressRestore(now: Double) -> [Effect] {
        guard let snap = restoring else { return [] }
        let match = SessionMatcher.match(windows: Array(windows.values), slots: snap.windows)
        var effects: [Effect] = []
        if match != restoreMatch {
            restoreMatch = match
            applySession(snap, match: match)
            if let f = focused { effects.append(.focus(f)) }
        }
        if match.count == snap.windows.count {
            restoring = nil
            effects.append(.log("session restored: all \(match.count) window(s) back in place"))
        } else if now >= restoreUntil {
            restoring = nil
            effects.append(.log("session restore finished: \(match.count) of \(snap.windows.count) window(s) came back"))
        }
        return effects
    }

    /// Rebuild workspaces from the snapshot using the matched live windows (missing ones pruned away).
    /// Unmatched live windows go to the workspace where their app mostly was, else stay where they are.
    mutating func applySession(_ snap: SessionSnapshot, match: [WindowID: WindowID]) {
        let slotToWindow = Dictionary(uniqueKeysWithValues: match.map { ($0.value, $0.key) })
        let present = Set(match.keys)
        var rebuilt: [String: Workspace] = [:]
        for var ws in snap.workspaces {
            ws.rename(slotToWindow)
            ws.prune(keep: present)
            rebuilt[ws.name] = ws
        }
        // Workspaces we have but the snapshot doesn't (configured, or created since): start empty.
        for name in workspaces.keys where rebuilt[name] == nil {
            rebuilt[name] = Workspace(name: name, layout: workspaces[name]!.layout, ratio: workspaces[name]!.ratio)
        }
        var newHome: [WindowID: String] = [:]
        for (name, ws) in rebuilt { for id in ws.windows { newHome[id] = name } }
        for id in windows.keys.sorted() where newHome[id] == nil {
            let app = windows[id].map { $0.bundleID ?? $0.app }
            let target = snap.windows.first { $0.appKey == app && rebuilt[$0.workspace] != nil }?.workspace ?? home[id] ?? active
            if rebuilt[target] == nil { rebuilt[target] = Workspace(name: target, layout: settings.defaultLayout, ratio: settings.ratio) }
            if let r = workspaces[home[id] ?? ""]?.floating[id] {
                rebuilt[target]!.floating[id] = r
            } else {
                rebuilt[target]!.insertTile(id, afterTile: rebuilt[target]!.order.last)
            }
            if rebuilt[target]!.focused == nil { rebuilt[target]!.focused = id }
            newHome[id] = target
        }
        workspaces = rebuilt
        home = newHome
        for name in settings.workspaces { ensureWorkspace(name) }
        // Group ids from the snapshot must never be handed out again.
        let maxGroup = rebuilt.values.flatMap(\.groups.keys).compactMap { Int($0.raw.dropFirst("group:".count)) }.max() ?? 0
        groupCounter = max(groupCounter, maxGroup)
        // Displays by name (ids change between boots); syncDisplays fixes whatever is missing.
        let idByName = Dictionary(displays.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        visible = Dictionary(snap.visible.compactMap { name, ws in idByName[name].map { ($0, ws) } }, uniquingKeysWith: { a, _ in a })
        assigned = Dictionary(uniqueKeysWithValues: snap.assigned.compactMap { ws, name in idByName[name].map { (ws, $0) } })
        ensureWorkspace(snap.active)
        active = snap.active
        previous = nil
        syncDisplays()
    }

    // MARK: - Groups

    mutating func newGroupID() -> WindowID {
        groupCounter += 1
        return WindowID("group:\(groupCounter)")
    }

    /// `group` (toggle) / `group <dir>` (join the neighbour's tile).
    mutating func group(_ d: Direction?) -> [Effect] {
        guard let f = focused, activeWorkspace.floating[f] == nil, let ft = activeWorkspace.tile(of: f) else { return [] }
        let style = settings.groups.style
        guard let d else {
            if activeWorkspace.groups[ft] != nil {
                update(active) { $0.dissolve(ft) }
            } else {
                let gid = newGroupID()
                update(active) { $0.wrapInGroup(f, groupID: gid, style: style) }
            }
            return []
        }
        // The neighbour must be on this workspace (no grouping across displays).
        let mine = frames(of: active, tiledOnly: true)
        guard let n = Layout.neighbour(of: f, d, in: mine), let nt = activeWorkspace.tile(of: n), nt != ft else { return [] }
        let gid = newGroupID()
        update(active) { ws in
            ws.remove(f)
            // Removing f may have dissolved its old group and renamed tiles; re-find the target.
            guard let target = ws.tile(of: n) else { return }
            ws.join(f, into: target, groupID: gid, style: style)
            ws.setFocused(f)
        }
        return [.focus(f)]
    }

    mutating func ungroup() -> [Effect] {
        guard let f = focused, let g = activeWorkspace.group(of: f) else { return [] }
        update(active) { ws in
            ws.remove(f)
            let after = ws.groups[g] != nil ? g : ws.tile(of: ws.windows.first { $0 != f } ?? f)
            ws.insertTile(f, afterTile: after)
            ws.setFocused(f)
        }
        return [.focus(f)]
    }

    mutating func cycleGroup(_ step: Int, now: Double) -> [Effect] {
        guard let f = focused, let g = activeWorkspace.group(of: f), let grp = activeWorkspace.groups[g],
              grp.members.count > 1, let i = grp.members.firstIndex(of: grp.active) else { return [] }
        let next = grp.members[(i + step + grp.members.count) % grp.members.count]
        update(active) { $0.setFocused(next) }
        lastSwitch = now   // the parked member's focus echo must not switch the tab back
        return [.focus(next)]
    }

    /// Reorder: the shown tab swaps with its neighbour in the strip. Stops at either end (like browser tabs).
    mutating func moveTab(_ d: Direction) {
        guard let f = focused, let g = activeWorkspace.group(of: f),
              let i = activeWorkspace.groups[g]?.members.firstIndex(of: f) else { return }
        let j = i + (d == .left || d == .up ? -1 : 1)
        update(active) { ws in
            guard ws.groups[g]!.members.indices.contains(j) else { return }
            ws.groups[g]!.members.swapAt(i, j)
        }
    }

    /// Show tab `n` (1-based) of the focused group.
    mutating func showTab(_ n: Int, now: Double) -> [Effect] {
        guard let f = focused, let g = activeWorkspace.group(of: f), let grp = activeWorkspace.groups[g],
              grp.members.indices.contains(n - 1) else { return [] }
        let target = grp.members[n - 1]
        guard target != grp.active else { return [] }
        update(active) { $0.setFocused(target) }
        lastSwitch = now   // ignore the parked tab's focus echo
        return [.focus(target)]
    }

    mutating func setGroupStyle(_ st: GroupStyle?) {
        guard let f = focused, let g = activeWorkspace.group(of: f) else { return }
        update(active) { ws in
            let cur = ws.groups[g]!.style
            ws.groups[g]!.style = st ?? (cur == .tabbed ? .stacked : .tabbed)
        }
    }

    // MARK: - Displays

    func pinnedDisplay(_ name: String) -> Display? { settings.workspaceDisplays[name]?.resolve(in: displays) }

    /// Re-establish the display invariants after displays or settings changed:
    /// assignments to vanished displays fall back to primary, pins apply, the focused workspace is visible,
    /// and every display shows a workspace (its own first, then the next free one in order).
    mutating func syncDisplays() {
        let ids = Set(displays.map(\.id))
        visible = visible.filter { ids.contains($0.key) }
        assigned = assigned.filter { ids.contains($0.value) }
        for name in settings.workspaceDisplays.keys {
            if let d = pinnedDisplay(name) { assigned[name] = d.id }
        }
        guard !displays.isEmpty else { return }
        // A visible workspace pinned elsewhere goes back to its pinned display (e.g. monitor re-plugged).
        for (d, name) in visible.sorted(by: { $0.key < $1.key }) {
            if let p = pinnedDisplay(name), p.id != d {
                visible[d] = nil
                visible[p.id] = name
            }
        }
        if !isVisible(active) {
            let d = display(of: active).id
            visible[d] = active
            assigned[active] = d
        }
        let names = settings.workspaces + workspaces.keys.sorted().filter { !settings.workspaces.contains($0) }
        for d in Display.ordered(displays) where visible[d.id] == nil {
            let free = names.filter { !isVisible($0) }
            let pick = free.first { assigned[$0] == d.id } ?? free.first { assigned[$0] == nil && pinnedDisplay($0) == nil }
            guard let pick else { continue }
            ensureWorkspace(pick)
            visible[d.id] = pick
            assigned[pick] = d.id
        }
        for (d, name) in visible { assigned[name] = d }
    }

    /// Keep a floating frame at the same relative spot when it changes display.
    static func translate(_ r: Rect, from: Display, to: Display) -> Rect {
        let a = from.visibleFrame, b = to.visibleFrame
        let w = min(r.width, b.width), h = min(r.height, b.height)
        let x = b.minX + (r.minX - a.minX) / max(1, a.width) * b.width
        let y = b.minY + (r.minY - a.minY) / max(1, a.height) * b.height
        return Rect(x: min(max(x, b.minX), b.maxX - w), y: min(max(y, b.minY), b.maxY - h), width: w, height: h)
    }

    // MARK: - Helpers

    mutating func ensureWorkspace(_ name: String) {
        if workspaces[name] == nil {
            workspaces[name] = Workspace(name: name, layout: settings.defaultLayout, ratio: settings.ratio)
        }
    }

    mutating func update(_ name: String, _ body: (inout Workspace) -> Void) {
        ensureWorkspace(name)
        body(&workspaces[name]!)
    }

    /// Configured workspaces in order, plus any created dynamically, cycled by `step`.
    func cycledWorkspace(_ step: Int) -> String {
        var names = settings.workspaces
        for extra in workspaces.keys.sorted() where !names.contains(extra) { names.append(extra) }
        guard let i = names.firstIndex(of: active) else { return names.first ?? active }
        return names[(i + step + names.count) % names.count]
    }
}

extension LayoutTree {
    /// Orientation of the split directly containing `id`.
    func parentOrientation(of id: WindowID) -> Orientation? {
        guard let p = path(to: id) else { return nil }
        return split(at: p.dropLast())?.orientation
    }
}
