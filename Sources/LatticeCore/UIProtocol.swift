/// Messages between the controller (`lattice run`) and the UI helper (`lattice-ui`).
/// Transport-agnostic Codable values — JSON lines over pipes today, XPC once the signed .app exists.
public enum UIProtocol {
    public static let version = 4
}

public struct HUDItem: Hashable, Codable, Sendable {
    public var key: String
    public var label: String
    /// Leads to another mode (shown with a "+" like which-key).
    public var isMode: Bool
    public init(key: String, label: String, isMode: Bool) { self.key = key; self.label = label; self.isMode = isMode }
}

public struct HUDModel: Hashable, Codable, Sendable {
    public var title: String
    public var items: [HUDItem]
    public var sticky: Bool
    public init(title: String, items: [HUDItem], sticky: Bool) { self.title = title; self.items = items; self.sticky = sticky }
}

public struct PaletteItem: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case window, workspace, layout, command }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// Command text to run when chosen (parsed by the controller, never by the UI).
    public var command: String

    public init(id: String, kind: Kind, title: String, subtitle: String, command: String) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.command = command
    }
}

/// Bar placement + content. `frame` is in AX coordinates (top-left origin).
public struct BarModel: Hashable, Codable, Sendable {
    /// The display this bar sits on; its workspaces widget lists that display's workspaces.
    public var displayID: UInt32
    public var frame: Rect
    public var settings: BarSettings
    public init(displayID: UInt32, frame: Rect, settings: BarSettings) {
        self.displayID = displayID; self.frame = frame; self.settings = settings
    }
}

/// Controller → UI.
public enum UIRequest: Hashable, Codable, Sendable {
    case hud(HUDModel?)
    case openPalette([PaletteItem])
    case closePalette
    case theme(Theme)
    /// Focus border around this AX-coordinate frame; nil hides it.
    case border(Rect?)
    /// One bar per display (empty = no bars).
    case bars([BarModel])
    case state(BarState)
    /// Tab strips of the groups on screen.
    case groups([GroupStrip])
    /// Hint labels to show (empty = hide).
    case hints([HintBadge])
    case quit
}

/// UI → controller.
public enum UIReply: Hashable, Codable, Sendable {
    case ready(version: Int)
    case chose(id: String)
    case cancelled
    /// Run a command (e.g. clicking a workspace in the bar). The controller parses and validates it.
    case run(command: String)
    case log(String)
}

/// A group's tab strip: where it goes (AX coordinates) and what it lists.
public struct GroupStrip: Hashable, Codable, Sendable {
    public struct Tab: Hashable, Codable, Sendable {
        public var window: String
        public var app: String
        public var title: String
        public var active: Bool
        public init(window: String, app: String, title: String, active: Bool) {
            self.window = window; self.app = app; self.title = title; self.active = active
        }
    }

    public var id: String
    public var frame: Rect
    public var style: GroupStyle
    /// The focused window is in this group.
    public var focused: Bool
    public var tabs: [Tab]

    public init(id: String, frame: Rect, style: GroupStyle, focused: Bool, tabs: [Tab]) {
        self.id = id; self.frame = frame; self.style = style; self.focused = focused; self.tabs = tabs
    }
}
