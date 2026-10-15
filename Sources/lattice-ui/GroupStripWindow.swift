import AppKit
import LatticeCore
import SwiftUI

/// Tab strips for groups: one non-activating panel per visible group, in the space the engine reserved
/// at the top of the group's tile. Clicking a tab focuses that window (via the controller).
@MainActor
final class GroupStripManager {
    private let store: ThemeStore
    private var panels: [String: (panel: NSPanel, model: StripModel)] = [:]
    var onRun: ((String) -> Void)?

    init(store: ThemeStore) { self.store = store }

    func show(_ strips: [GroupStrip]) {
        let wanted = Set(strips.map(\.id))
        for (id, p) in panels where !wanted.contains(id) {
            p.panel.orderOut(nil)
            panels[id] = nil
        }
        for strip in strips {
            let entry = panels[strip.id] ?? makePanel()
            entry.model.strip = strip
            entry.panel.setFrame(cocoaRect(strip.frame), display: true)
            entry.panel.orderFrontRegardless()
            panels[strip.id] = entry
        }
    }

    private func makePanel() -> (panel: NSPanel, model: StripModel) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]   // stay on Lattice's Space (not every macOS Space)
        let model = StripModel()
        model.run = { [weak self] cmd in self?.onRun?(cmd) }
        panel.contentView = NSHostingView(rootView: GroupStripView(model: model, store: store))
        return (panel, model)
    }
}

@MainActor
final class StripModel: ObservableObject {
    @Published var strip: GroupStrip?
    var run: ((String) -> Void)?
}

struct GroupStripView: View {
    @ObservedObject var model: StripModel
    @ObservedObject var store: ThemeStore

    var body: some View {
        if let s = model.strip {
            let p = store.palette
            let layout = s.style == .tabbed
                ? AnyLayout(HStackLayout(spacing: 2))
                : AnyLayout(VStackLayout(spacing: 2))
            layout {
                ForEach(s.tabs, id: \.window) { tab in
                    HStack(spacing: 6) {
                        Text(tab.app).fontWeight(.semibold)
                        if !tab.title.isEmpty, tab.title != tab.app {
                            Text(tab.title).foregroundStyle(tab.active ? p.background.color.opacity(0.8) : p.muted.color)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .font(store.font(0.9))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(tab.active && s.focused ? p.background.color : (tab.active ? p.foreground.color : p.muted.color))
                    .background(
                        // Active tab: accent when the group has focus, raised surface otherwise.
                        // Inactive tabs: a dimmer surface, so they still read as tabs.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.active ? (s.focused ? p.accent.color : p.surface.color) : p.surface.color.opacity(0.45))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.run?("focus-window \(tab.window)") }
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opaque base: whatever is behind the strip (other apps) must never show through.
            .background(p.background.color)
        }
    }
}
