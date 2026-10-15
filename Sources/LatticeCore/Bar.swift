/// The bar: what it shows (widgets), where it sits, and the live state it renders.

public enum BarWidget: Hashable, Codable, Sendable {
    /// Workspace pills; `showEmpty` also lists configured workspaces without windows.
    case workspaces(showEmpty: Bool)
    /// Focused app — window title, truncated.
    case focused(maxLength: Int)
    case layout
    /// Current which-key mode (hidden when none).
    case mode
    case clock(format: String)
    case battery
    case cpu
    case memory
    /// Output of a shell command, refreshed every `interval` seconds. Plain text, or JSON
    /// `{"text": …, "color": "#rrggbb", "icon": "sf.symbol.name"}`.
    case script(command: String, interval: Double)
    case text(String)

    public static let names = ["workspaces", "focused", "layout", "mode", "clock", "battery", "cpu", "memory", "script", "text"]
}

public struct BarSettings: Hashable, Codable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable { case top, bottom }
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Windows tile around the bar.
        case reserve
        /// The bar floats above windows.
        case overlay
    }

    public var enabled: Bool
    public var position: Position
    public var mode: Mode
    public var height: Double
    public var left: [BarWidget]
    public var center: [BarWidget]
    public var right: [BarWidget]

    public init(
        enabled: Bool = false, position: Position = .top, mode: Mode = .reserve, height: Double = 30,
        left: [BarWidget] = [], center: [BarWidget] = [], right: [BarWidget] = []
    ) {
        self.enabled = enabled; self.position = position; self.mode = mode; self.height = height
        self.left = left; self.center = center; self.right = right
    }

    /// Bar frame inside a display's visible area (below the menu bar / above the Dock).
    public func frame(in visible: Rect) -> Rect {
        let y = position == .top ? visible.minY : visible.maxY - height
        return Rect(x: visible.minX, y: y, width: visible.width, height: height)
    }

    /// The visible area left for tiling once the bar has taken its share.
    public func tilingArea(in visible: Rect) -> Rect {
        guard enabled, mode == .reserve else { return visible }
        let y = position == .top ? visible.minY + height : visible.minY
        return Rect(x: visible.minX, y: y, width: visible.width, height: max(1, visible.height - height))
    }
}

public struct BorderSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
}

/// Window-manager state the bar renders. Sent to the UI only when it changes.
public struct BarState: Hashable, Codable, Sendable {
    public struct WorkspaceInfo: Hashable, Codable, Sendable {
        public var name: String
        /// Focused workspace.
        public var active: Bool
        public var windows: Int
        /// Display the workspace lives on — each bar lists its own display's workspaces.
        public var display: UInt32
        /// Shown on its display right now (with several displays, more than one workspace is visible).
        public var visible: Bool
        public init(name: String, active: Bool, windows: Int, display: UInt32 = 0, visible: Bool = false) {
            self.name = name; self.active = active; self.windows = windows; self.display = display; self.visible = visible
        }
    }

    public var workspaces: [WorkspaceInfo]
    public var focusedApp: String?
    public var focusedTitle: String?
    public var layout: LayoutKind
    public var mode: String?

    public init(workspaces: [WorkspaceInfo], focusedApp: String?, focusedTitle: String?, layout: LayoutKind, mode: String?) {
        self.workspaces = workspaces; self.focusedApp = focusedApp; self.focusedTitle = focusedTitle
        self.layout = layout; self.mode = mode
    }

    /// Configured workspaces in order, then any created on the fly.
    public static func from(_ engine: Engine, mode: String?) -> BarState {
        let names = engine.settings.workspaces + engine.workspaces.keys.sorted().filter { !engine.settings.workspaces.contains($0) }
        let infos = names.map { n in
            WorkspaceInfo(name: n, active: n == engine.active, windows: engine.workspaces[n]?.windows.count ?? 0,
                          display: engine.display(of: n).id, visible: engine.isVisible(n))
        }
        let f = engine.focused.flatMap { engine.windows[$0] }
        return BarState(workspaces: infos, focusedApp: f?.app, focusedTitle: f?.title,
                        layout: engine.activeWorkspace.layout, mode: mode)
    }
}
