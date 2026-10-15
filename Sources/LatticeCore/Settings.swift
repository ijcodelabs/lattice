import Foundation

/// Fully-validated settings. Produced by LatticeConfig from YAML; the core never sees raw YAML.
public struct Settings: Hashable, Sendable {
    public var mod: KeyChord.Modifiers
    public var gaps: Gaps
    public var defaultLayout: LayoutKind
    /// Dwindle split ratio / master column ratio.
    public var ratio: Double
    /// Named workspaces in order (first = initial).
    public var workspaces: [String]
    public var focusNewWindows: Bool
    public var bindings: [Binding]
    /// Key modes (leader / which-key), by name. Entered with the `mode NAME` command.
    public var modes: [String: KeyMode]
    public var rules: [WindowRule]
    public var theme: Theme
    public var borders: BorderSettings
    public var bar: BarSettings
    /// Workspaces pinned to a display (config `workspace-displays:`); others go where they're opened.
    public var workspaceDisplays: [String: DisplaySelector] = [:]
    public var groups = GroupSettings()
    /// At the last window in a direction (and no display beyond it), `focus` wraps to the other side.
    public var focusWrap = true
    public var session = SessionSettings()

    public init(
        mod: KeyChord.Modifiers = [.ctrl, .alt], gaps: Gaps = Gaps(inner: 8, outer: 8), defaultLayout: LayoutKind = .dwindle,
        ratio: Double = 0.5, workspaces: [String] = (1...9).map(String.init), focusNewWindows: Bool = true,
        bindings: [Binding] = [], modes: [String: KeyMode] = [:], rules: [WindowRule] = [],
        theme: Theme = .fallback, borders: BorderSettings = BorderSettings(), bar: BarSettings = BarSettings()
    ) {
        self.mod = mod; self.gaps = gaps; self.defaultLayout = defaultLayout; self.ratio = ratio
        self.workspaces = workspaces; self.focusNewWindows = focusNewWindows; self.bindings = bindings; self.modes = modes; self.rules = rules
        self.theme = theme; self.borders = borders; self.bar = bar
    }
}

public struct Binding: Hashable, Sendable {
    public var chord: KeyChord
    public var command: Command
    /// Shown in the which-key HUD; defaults to the command text.
    public var label: String?
    public init(chord: KeyChord, command: Command, label: String? = nil) {
        self.chord = chord; self.command = command; self.label = label
    }
    public var displayLabel: String { label ?? command.description }
}

/// A which-key mode: a small keymap active after a leader chord.
public struct KeyMode: Hashable, Sendable {
    public var name: String
    public var label: String?
    /// Sticky modes (e.g. resize) stay active after a command until Escape/timeout.
    public var sticky: Bool
    /// Seconds of inactivity before the mode exits on its own; 0 = never.
    public var timeout: Double
    public var bindings: [Binding]

    public init(name: String, label: String? = nil, sticky: Bool = false, timeout: Double = 4, bindings: [Binding] = []) {
        self.name = name; self.label = label; self.sticky = sticky; self.timeout = timeout; self.bindings = bindings
    }
}

/// "Windows matching X float / go to workspace Y". All given matchers must match.
public struct WindowRule: Hashable, Sendable {
    public var app: String?
    public var bundleID: String?
    public var title: String?
    public var float: Bool?
    public var workspace: String?

    public init(app: String? = nil, bundleID: String? = nil, title: String? = nil, float: Bool? = nil, workspace: String? = nil) {
        self.app = app; self.bundleID = bundleID; self.title = title; self.float = float; self.workspace = workspace
    }

    /// `app` and `title` are case-insensitive regular expressions (validated at config load); `bundleID` is exact.
    public func matches(_ w: WindowSnapshot) -> Bool {
        if let bundleID, w.bundleID != bundleID { return false }
        if let app, !Self.regexMatch(app, w.app) { return false }
        if let title, !Self.regexMatch(title, w.title) { return false }
        return app != nil || bundleID != nil || title != nil
    }

    static func regexMatch(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func isValidPattern(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }
}

public struct GroupSettings: Hashable, Codable, Sendable {
    /// Draw a tab strip on top of each group (its height is taken from the group's tile).
    public var tabBar: Bool
    /// Style for new groups.
    public var style: GroupStyle
    /// Height of one tab row (stacked groups use one row per member).
    public var tabHeight: Double

    public init(tabBar: Bool = true, style: GroupStyle = .tabbed, tabHeight: Double = 26) {
        self.tabBar = tabBar; self.style = style; self.tabHeight = tabHeight
    }
}
