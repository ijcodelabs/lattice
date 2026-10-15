/// Everything a key binding (or the CLI / palette later) can ask the WM to do.
public enum SessionAction: String, Hashable, Codable, Sendable, CaseIterable { case save, restore, forget }

/// What picking a hint does.
public enum HintAction: String, Hashable, Codable, Sendable, CaseIterable { case focus, swap }

public enum Command: Hashable, Codable, Sendable, CustomStringConvertible {
    case focus(Direction)
    case move(Direction)
    case workspace(String)
    case workspaceBackAndForth
    case workspaceNext
    case workspacePrev
    case moveToWorkspace(String, follow: Bool)
    case layout(LayoutKind)
    case layoutNext
    case split(Orientation)
    case toggleFloating
    case resize(grow: Bool, axis: Orientation?, amount: Double)
    case balance
    case exec(String)
    case retile
    case reload
    case quit
    /// Enter a key mode (leader / which-key). Handled by `KeyRouter`, not the engine.
    case mode(String)
    case modeExit
    case palette
    /// Jump to a specific window (switching workspace if needed). Used by the palette.
    case focusWindow(WindowID)
    case focusDisplay(DisplayTarget)
    /// Move the focused window to the workspace shown on that display (and follow it).
    case moveToDisplay(DisplayTarget)
    /// Move the whole current workspace to that display.
    case moveWorkspaceToDisplay(DisplayTarget)
    /// No direction: toggle the focused window's group (wrap into a group of one / dissolve the group).
    /// With a direction: put the focused window into the neighbouring tile's group (creating it).
    case group(Direction?)
    /// Take the focused window out of its group into its own tile.
    case ungroup
    /// Show the next/previous member of the focused group.
    case groupCycle(Int)
    /// Set (or toggle, when nil) the focused group's style.
    case groupStyle(GroupStyle?)
    /// Move the shown tab one position within its group (left/up = earlier, right/down = later).
    case groupMove(Direction)
    /// Show tab N (1-based) of the focused group.
    case groupTab(Int)
    /// `session save|restore|forget`.
    case session(SessionAction)
    /// Label every visible window with letters; typing one focuses (or swaps with) that window.
    case hints(HintAction)
    /// Swap the focused window with another one (any visible workspace/display). Used by `hints swap`.
    case swapWindow(WindowID)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknown(String)
        case badArgument(command: String, argument: String, expected: String)

        public var description: String {
            switch self {
            case .empty: "empty command"
            case let .unknown(c): "unknown command '\(c)' (see docs/config.md#commands)"
            case let .badArgument(c, a, e): "'\(c)': bad argument '\(a)', expected \(e)"
            }
        }
    }

    /// Parses the command language used in config bindings, e.g. `focus left`, `workspace 3`,
    /// `move-to-workspace 3 follow`, `layout dwindle`, `resize grow width 0.1`, `exec open -a Ghostty`.
    public static func parse(_ text: String) throws(ParseError) -> Command {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first?.lowercased() else { throw .empty }
        let args = Array(words.dropFirst())
        let arg = args.first?.lowercased()

        func direction() throws(ParseError) -> Direction {
            guard let a = arg, let d = Direction(rawValue: a) else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "left|right|up|down")
            }
            return d
        }

        switch name {
        case "focus": return .focus(try direction())
        case "move": return .move(try direction())
        case "workspace":
            switch arg {
            case nil: throw .badArgument(command: name, argument: "", expected: "a workspace name, next, prev or back-and-forth")
            case "back-and-forth": return .workspaceBackAndForth
            case "next": return .workspaceNext
            case "prev": return .workspacePrev
            default: return .workspace(args[0])
            }
        case "move-to-workspace":
            guard let ws = args.first else { throw .badArgument(command: name, argument: "", expected: "a workspace name") }
            if args.count > 1, args[1].lowercased() != "follow" {
                throw .badArgument(command: name, argument: args[1], expected: "follow (or nothing)")
            }
            return .moveToWorkspace(ws, follow: args.count > 1)
        case "layout":
            if arg == "next" { return .layoutNext }
            guard let a = arg, let k = LayoutKind(rawValue: a) else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "tree|dwindle|master|monocle|next")
            }
            return .layout(k)
        case "split":
            switch arg {
            case "horizontal", "h": return .split(.horizontal)
            case "vertical", "v": return .split(.vertical)
            default: throw .badArgument(command: name, argument: arg ?? "", expected: "horizontal|vertical")
            }
        case "toggle-floating": return .toggleFloating
        case "resize":
            guard let a = arg, a == "grow" || a == "shrink" else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "grow|shrink [width|height] [amount]")
            }
            var axis: Orientation?
            var amount = 0.05
            for extra in args.dropFirst() {
                switch extra.lowercased() {
                case "width": axis = .horizontal
                case "height": axis = .vertical
                default:
                    guard let v = Double(extra), v > 0, v < 1 else {
                        throw .badArgument(command: name, argument: extra, expected: "width|height or an amount in (0, 1)")
                    }
                    amount = v
                }
            }
            return .resize(grow: a == "grow", axis: axis, amount: amount)
        case "balance": return .balance
        case "exec":
            guard !args.isEmpty else { throw .badArgument(command: name, argument: "", expected: "a shell command") }
            // Keep the original spacing of the shell command.
            let rest = text.drop { $0.isWhitespace }.dropFirst(4).drop { $0.isWhitespace }
            return .exec(String(rest))
        case "mode":
            guard let m = args.first else { throw .badArgument(command: name, argument: "", expected: "a mode name") }
            return .mode(m)
        case "mode-exit": return .modeExit
        case "palette": return .palette
        case "focus-window":
            guard let w = args.first else { throw .badArgument(command: name, argument: "", expected: "a window id") }
            return .focusWindow(WindowID(w))
        case "focus-display", "move-to-display", "move-workspace-to-display":
            guard let a = arg, let t = DisplayTarget.parse(a) else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "left|right|up|down|next|prev")
            }
            switch name {
            case "focus-display": return .focusDisplay(t)
            case "move-to-display": return .moveToDisplay(t)
            default: return .moveWorkspaceToDisplay(t)
            }
        case "group":
            guard let a = arg else { return .group(nil) }
            guard let d = Direction(rawValue: a) else {
                throw .badArgument(command: name, argument: a, expected: "left|right|up|down (or nothing to toggle)")
            }
            return .group(d)
        case "ungroup": return .ungroup
        case "group-next": return .groupCycle(1)
        case "group-prev": return .groupCycle(-1)
        case "group-style":
            switch arg {
            case "toggle": return .groupStyle(nil)
            case let a?: if let st = GroupStyle(rawValue: a) { return .groupStyle(st) }; fallthrough
            default: throw .badArgument(command: name, argument: arg ?? "", expected: "tabbed|stacked|toggle")
            }
        case "group-move":
            guard let a = arg, let d = Direction(rawValue: a) else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "left|right|up|down")
            }
            return .groupMove(d)
        case "group-tab":
            guard let a = arg, let n = Int(a), n >= 1 else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "a tab number (1, 2, …)")
            }
            return .groupTab(n)
        case "hints":
            guard let a = arg else { return .hints(.focus) }
            guard let act = HintAction(rawValue: a) else { throw .badArgument(command: name, argument: a, expected: "focus|swap") }
            return .hints(act)
        case "swap-window":
            guard let w = args.first else { throw .badArgument(command: name, argument: "", expected: "a window id") }
            return .swapWindow(WindowID(w))
        case "session":
            guard let a = arg, let act = SessionAction(rawValue: a) else {
                throw .badArgument(command: name, argument: arg ?? "", expected: "save|restore|forget")
            }
            return .session(act)
        case "retile": return .retile
        case "reload": return .reload
        case "quit": return .quit
        default: throw .unknown(name)
        }
    }

    public var description: String {
        switch self {
        case let .focus(d): "focus \(d.rawValue)"
        case let .move(d): "move \(d.rawValue)"
        case let .workspace(w): "workspace \(w)"
        case .workspaceBackAndForth: "workspace back-and-forth"
        case .workspaceNext: "workspace next"
        case .workspacePrev: "workspace prev"
        case let .moveToWorkspace(w, f): "move-to-workspace \(w)\(f ? " follow" : "")"
        case let .layout(k): "layout \(k.rawValue)"
        case .layoutNext: "layout next"
        case let .split(o): "split \(o.rawValue)"
        case .toggleFloating: "toggle-floating"
        case let .resize(g, a, amt):
            "resize \(g ? "grow" : "shrink")\(a.map { $0 == .horizontal ? " width" : " height" } ?? "") \(amt)"
        case .balance: "balance"
        case let .exec(c): "exec \(c)"
        case let .mode(m): "mode \(m)"
        case .modeExit: "mode-exit"
        case .palette: "palette"
        case let .focusWindow(id): "focus-window \(id.raw)"
        case let .focusDisplay(t): "focus-display \(t)"
        case let .moveToDisplay(t): "move-to-display \(t)"
        case let .moveWorkspaceToDisplay(t): "move-workspace-to-display \(t)"
        case let .group(d): d.map { "group \($0.rawValue)" } ?? "group"
        case .ungroup: "ungroup"
        case let .groupCycle(step): step >= 0 ? "group-next" : "group-prev"
        case let .groupStyle(st): "group-style \(st?.rawValue ?? "toggle")"
        case let .groupMove(d): "group-move \(d.rawValue)"
        case let .groupTab(n): "group-tab \(n)"
        case let .session(act): "session \(act.rawValue)"
        case let .hints(act): act == .focus ? "hints" : "hints \(act.rawValue)"
        case let .swapWindow(id): "swap-window \(id.raw)"
        case .retile: "retile"
        case .reload: "reload"
        case .quit: "quit"
        }
    }
}
