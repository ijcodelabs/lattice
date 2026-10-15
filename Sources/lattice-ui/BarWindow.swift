import AppKit
import LatticeCore
import SwiftUI

/// One bar per display. All bars share one `BarContent` (state, system stats, script runners — so a
/// script runs once, not once per display); each bar filters workspaces to its own display.
@MainActor
final class BarManager {
    private let store: ThemeStore
    let content = BarContent()
    private var windows: [UInt32: BarWindow] = [:]
    var onRun: ((String) -> Void)? {
        get { content.run }
        set { content.run = newValue }
    }

    init(store: ThemeStore) { self.store = store }

    func show(_ models: [BarModel]) {
        content.setSettings(models.first?.settings)
        let wanted = Set(models.map(\.displayID))
        for (id, w) in windows where !wanted.contains(id) { w.close(); windows[id] = nil }
        for m in models {
            let w = windows[m.displayID] ?? BarWindow(store: store, content: content, displayID: m.displayID)
            windows[m.displayID] = w
            w.place(m.frame)
        }
    }

    func update(_ state: BarState) { content.state = state }
}

/// One bar: a borderless panel at the frame the controller computed (AX coordinates), so tiling and
/// bar always agree on the reserved space. Clicks work (workspaces) without activating the app.
@MainActor
final class BarWindow {
    private let panel: NSPanel

    init(store: ThemeStore, content: BarContent, displayID: UInt32) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]   // stay on Lattice's Space (not every macOS Space)
        panel.contentView = NSHostingView(rootView: BarView(content: content, store: store, displayID: displayID))
    }

    func place(_ frame: Rect) {
        panel.setFrame(cocoaRect(frame), display: true)
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// What the bar shows: settings (widgets), WM state, system stats and script outputs.
@MainActor
final class BarContent: ObservableObject {
    @Published private(set) var settings: BarSettings?
    @Published var state = BarState(workspaces: [], focusedApp: nil, focusedTitle: nil, layout: .dwindle, mode: nil)
    let stats = SystemStats()
    /// Script widgets keyed by command+interval, so a config reload keeps running ones.
    private(set) var scripts: [String: ScriptRunner] = [:]
    var run: ((String) -> Void)?

    func setSettings(_ s: BarSettings?) {
        settings = s
        let wanted = Set((s.map { $0.left + $0.center + $0.right } ?? []).compactMap { w -> String? in
            if case let .script(c, i) = w { return Self.key(c, i) } else { return nil }
        })
        for (k, runner) in scripts where !wanted.contains(k) { runner.stop(); scripts[k] = nil }
        for w in s.map({ $0.left + $0.center + $0.right }) ?? [] {
            if case let .script(c, i) = w, scripts[Self.key(c, i)] == nil {
                let r = ScriptRunner(command: c, interval: i)
                scripts[Self.key(c, i)] = r
                r.start()
            }
        }
        if s != nil { stats.start() }
    }

    static func key(_ command: String, _ interval: Double) -> String { "\(interval)|\(command)" }
}

struct BarView: View {
    @ObservedObject var content: BarContent
    @ObservedObject var store: ThemeStore
    let displayID: UInt32

    var body: some View {
        let p = store.palette
        ZStack {
            Rectangle().fill(p.background.color.opacity(store.theme.opacity))
            if let s = content.settings {
                ZStack {
                    HStack(spacing: 12) { widgets(s.left); Spacer(minLength: 0) }
                    HStack(spacing: 12) { widgets(s.center) }
                    HStack(spacing: 12) { Spacer(minLength: 0); widgets(s.right) }
                }
                .padding(.horizontal, 10)
            }
        }
        .font(store.font())
        .foregroundStyle(p.foreground.color)
    }

    @ViewBuilder
    func widgets(_ list: [BarWidget]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { _, w in
            WidgetView(widget: w, content: content, store: store, stats: content.stats, displayID: displayID)
        }
    }
}

struct WidgetView: View {
    let widget: BarWidget
    @ObservedObject var content: BarContent
    @ObservedObject var store: ThemeStore
    @ObservedObject var stats: SystemStats
    let displayID: UInt32

    var body: some View {
        let p = store.palette
        switch widget {
        case let .workspaces(showEmpty):
            HStack(spacing: 4) {
                // This display's workspaces. Focused = filled accent; shown here but not focused = accent outline.
                ForEach(content.state.workspaces.filter {
                    $0.display == displayID && (showEmpty || $0.active || $0.visible || $0.windows > 0)
                }, id: \.name) { ws in
                    Text(ws.name)
                        .font(store.font(weight: ws.active || ws.visible ? .bold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(ws.active ? p.accent.color : (ws.windows > 0 ? p.surface.color : .clear)))
                        .overlay(Capsule().strokeBorder(ws.visible && !ws.active ? p.accent.color : .clear, lineWidth: 1.5))
                        .foregroundStyle(ws.active ? p.background.color : (ws.windows > 0 || ws.visible ? p.foreground.color : p.muted.color))
                        .contentShape(Capsule())
                        .onTapGesture { content.run?("workspace \(ws.name)") }
                }
            }
        case let .focused(maxLength):
            let s = content.state
            let text = [s.focusedApp, s.focusedTitle.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " — ")
            Text(text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text).lineLimit(1)
        case .layout:
            Label(content.state.layout.rawValue, systemImage: icon(content.state.layout))
                .foregroundStyle(p.muted.color)
        case .mode:
            if let mode = content.state.mode {
                Text(mode.uppercased())
                    .font(store.font(0.85, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(p.accent.color))
                    .foregroundStyle(p.background.color)
            }
        case let .clock(format):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.formatter(format).string(from: ctx.date)).monospacedDigit()
            }
        case .battery:
            if let b = stats.battery {
                let low = b.percent <= 20 && !b.charging
                Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : batteryIcon(b.percent))
                    .foregroundStyle(low ? p.urgent.color : p.foreground.color)
                    .monospacedDigit()
            }
        case .cpu:
            Label("\(Int((stats.cpu * 100).rounded()))%", systemImage: "cpu")
                .foregroundStyle(stats.cpu > 0.85 ? p.urgent.color : p.foreground.color)
                .monospacedDigit()
        case .memory:
            Label("\(Int((stats.memory * 100).rounded()))%", systemImage: "memorychip")
                .foregroundStyle(stats.memory > 0.9 ? p.urgent.color : p.foreground.color)
                .monospacedDigit()
        case let .script(command, interval):
            if let runner = content.scripts[BarContent.key(command, interval)] {
                ScriptView(runner: runner, store: store)
            }
        case let .text(t):
            Text(t)
        }
    }

    func icon(_ k: LayoutKind) -> String {
        switch k {
        case .tree: "square.split.2x2"
        case .dwindle: "rectangle.split.2x1"
        case .master: "sidebar.left"
        case .monocle: "square"
        }
    }

    func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    static var formatters: [String: DateFormatter] = [:]
    @MainActor static func formatter(_ f: String) -> DateFormatter {
        if let cached = formatters[f] { return cached }
        let d = DateFormatter()
        d.dateFormat = f
        formatters[f] = d
        return d
    }
}

struct ScriptView: View {
    @ObservedObject var runner: ScriptRunner
    @ObservedObject var store: ThemeStore

    var body: some View {
        let o = runner.output
        let color = o.color.flatMap(RGBA.parse)?.color ?? store.palette.foreground.color
        if let icon = o.icon {
            Label(o.text, systemImage: icon).foregroundStyle(color).lineLimit(1)
        } else {
            Text(o.text).foregroundStyle(color).lineLimit(1)
        }
    }
}
