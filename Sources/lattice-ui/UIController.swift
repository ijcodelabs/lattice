import AppKit
import LatticeCore
import SwiftUI

@MainActor
final class UIController {
    private let store = ThemeStore()
    private lazy var hud = HUDWindow(store: store)
    private lazy var palette = PaletteWindow(store: store)
    private lazy var border = BorderWindow(store: store)
    private lazy var bar = BarManager(store: store)
    private lazy var strips = GroupStripManager(store: store)
    private lazy var hints = HintManager(store: store)

    func start() {
        bar.onRun = { [weak self] cmd in self?.reply(.run(command: cmd)) }
        strips.onRun = { [weak self] cmd in self?.reply(.run(command: cmd)) }
        palette.onChoose = { [weak self] id in self?.reply(.chose(id: id)) }
        palette.onCancel = { [weak self] in self?.reply(.cancelled) }

        // stdin reader on its own thread; EOF means the controller is gone → exit.
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let request = try? JSONDecoder().decode(UIRequest.self, from: data) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { ui.handle(request) } }
            }
            exit(0)
        }
        reply(.ready(version: UIProtocol.version))
    }

    func handle(_ request: UIRequest) {
        switch request {
        case let .hud(model):
            if let model { hud.show(model) } else { hud.hide() }
            log(model.map { "hud: \($0.title) (\($0.items.count) keys)" } ?? "hud: hidden")
        case let .openPalette(items):
            hud.hide()
            palette.open(items)
            log("palette: open (\(items.count) items)")
        case .closePalette:
            palette.close()
        case let .theme(t):
            store.theme = t
            border.refresh()
            log("theme: \(t.name)")
        case let .border(frame):
            border.show(frame)
            if Self.debug { log("border: \(frame.map(\.description) ?? "hidden")") }
        case let .bars(models):
            bar.show(models)
            log(models.isEmpty ? "bars: none" : "bars: " + models.map { "#\($0.displayID) \($0.frame)" }.joined(separator: ", "))
        case let .hints(badges):
            hints.show(badges)
            if Self.debug { log("hints: " + badges.map { "\($0.label)[\($0.typed)]" }.joined(separator: " ")) }
        case let .groups(list):
            strips.show(list)
            if Self.debug {
                log("groups: " + list.map { s in
                    "\(s.id) \(s.style.rawValue) [" + s.tabs.map { $0.active ? "*\($0.title)" : $0.title }.joined(separator: " | ") + "] at \(s.frame)"
                }.joined(separator: ", "))
            }
        case let .state(st):
            bar.update(st)
            if Self.debug {
                let ws = st.workspaces.map { "\($0.name)\($0.active ? "*" : "")(\($0.windows))" }.joined(separator: " ")
                log("state: [\(ws)] focused=\(st.focusedApp ?? "-") layout=\(st.layout.rawValue) mode=\(st.mode ?? "-")")
            }
        case .quit:
            exit(0)
        }
    }

    static let debug = ProcessInfo.processInfo.environment["LATTICE_DEBUG_UI"] != nil

    func reply(_ r: UIReply) {
        guard var data = try? JSONEncoder().encode(r) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("[ui] \(message)\n".utf8))
    }
}

// MARK: - HUD

/// Which-key pop-up: bottom-centre, never takes focus or mouse clicks.
@MainActor
final class HUDWindow {
    private let panel: NSPanel
    private let store: ThemeStore

    init(store: ThemeStore) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func show(_ model: HUDModel) {
        let host = NSHostingView(rootView: HUDView(model: model, store: store))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 60, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

struct HUDView: View {
    let model: HUDModel
    @ObservedObject var store: ThemeStore
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 150, maximum: 300), alignment: .leading), count: min(3, max(1, (model.items.count + 3) / 4)))
    }

    var body: some View {
        let p = store.palette
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.title).font(store.font(1.1, weight: .semibold))
                Spacer()
                Text(model.sticky ? "esc to finish" : "esc to cancel").font(store.font(0.85)).foregroundStyle(p.muted.color)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(model.items, id: \.key) { item in
                    HStack(spacing: 8) {
                        Text(item.key)
                            .font(store.font(weight: .semibold, mono: true))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(p.surface.color))
                        Text(item.isMode ? "+ \(item.label)" : item.label)
                            .font(store.font())
                            .foregroundStyle(item.isMode ? p.accent.color : p.foreground.color)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 320)
        .foregroundStyle(p.foreground.color)
        .background(ThemedPanelBackground(store: store, radius: store.theme.radius + 4))
    }
}

// MARK: - Palette

/// A borderless panel that can still take keyboard focus (plain borderless windows can't).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PaletteWindow {
    private let panel: KeyPanel
    private let state = PaletteState()
    private let store: ThemeStore
    var onChoose: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var resignObserver: NSObjectProtocol?

    init(store: ThemeStore) {
        self.store = store
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        state.choose = { [weak self] id in self?.finish(chosen: id) }
        state.cancel = { [weak self] in self?.finish(chosen: nil) }
        panel.contentView = NSHostingView(rootView: PaletteView(state: state, store: store))
    }

    func open(_ items: [PaletteItem]) {
        state.reset(items)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - 310, y: screen.maxY - 420 - screen.height * 0.15, width: 620, height: 420), display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Clicking elsewhere cancels, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(chosen: nil) }
        }
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
    }

    private func finish(chosen id: String?) {
        guard panel.isVisible else { return }
        close()
        if let id { onChoose?(id) } else { onCancel?() }
    }
}

@MainActor
final class PaletteState: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published private(set) var shown: [PaletteItem] = []
    @Published var selection = 0
    private var all: [PaletteItem] = []
    var choose: ((String) -> Void)?
    var cancel: (() -> Void)?

    func reset(_ items: [PaletteItem]) {
        all = items
        query = ""
        refilter()
    }

    func refilter() {
        shown = Palette.filter(all, query: query)
        selection = 0
    }

    func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        selection = (selection + delta + shown.count) % shown.count
    }

    func submit() {
        guard shown.indices.contains(selection) else { return }
        choose?(shown[selection].id)
    }
}

struct PaletteView: View {
    @ObservedObject var state: PaletteState
    @ObservedObject var store: ThemeStore
    @FocusState private var focused: Bool

    var body: some View {
        let p = store.palette
        VStack(spacing: 0) {
            TextField("Windows, workspaces, layouts, commands…", text: $state.query)
                .textFieldStyle(.plain)
                .font(store.font(1.5))
                .padding(14)
                .focused($focused)
                .onSubmit { state.submit() }
                .onKeyPress(.upArrow) { state.move(-1); return .handled }
                .onKeyPress(.downArrow) { state.move(1); return .handled }
                .onKeyPress(.escape) { state.cancel?(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                List(Array(state.shown.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Image(systemName: icon(item.kind)).frame(width: 18).foregroundStyle(p.muted.color)
                        Text(item.title).font(store.font()).foregroundStyle(p.foreground.color).lineLimit(1)
                        Spacer()
                        Text(item.subtitle).font(store.font(0.85)).foregroundStyle(p.muted.color).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(index == state.selection ? RoundedRectangle(cornerRadius: 6).fill(p.accent.color.opacity(0.3)) : nil)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture { state.selection = index; state.submit() }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: state.selection) { _, new in proxy.scrollTo(new) }
            }
        }
        .foregroundStyle(p.foreground.color)
        .background(ThemedPanelBackground(store: store, radius: store.theme.radius + 4))
        .onAppear { focused = true }
        .onChange(of: state.query) { _, _ in focused = true }
    }

    func icon(_ kind: PaletteItem.Kind) -> String {
        switch kind {
        case .window: "macwindow"
        case .workspace: "square.grid.3x3"
        case .layout: "rectangle.split.3x1"
        case .command: "command"
        }
    }
}
