import AppKit
import LatticeCore
import SwiftUI

/// Hint badges: a big label centred on each window (Vimium-style). Click-through, above everything.
@MainActor
final class HintManager {
    private let store: ThemeStore
    private var panels: [NSPanel] = []

    init(store: ThemeStore) { self.store = store }

    func show(_ badges: [HintBadge]) {
        while panels.count > badges.count { panels.removeLast().orderOut(nil) }
        while panels.count < badges.count { panels.append(makePanel()) }
        for (panel, badge) in zip(panels, badges) {
            let size = NSSize(width: 34 + 30 * Double(badge.label.count), height: 64)
            let c = cocoaRect(badge.frame)
            panel.setFrame(NSRect(x: c.midX - size.width / 2, y: c.midY - size.height / 2, width: size.width, height: size.height), display: true)
            panel.contentView = NSHostingView(rootView: HintBadgeView(badge: badge, store: store))
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}

struct HintBadgeView: View {
    let badge: HintBadge
    @ObservedObject var store: ThemeStore

    var body: some View {
        let p = store.palette
        HStack(spacing: 0) {
            Text(badge.typed.uppercased()).foregroundStyle(p.background.color.opacity(0.45))
            Text(String(badge.label.dropFirst(badge.typed.count)).uppercased()).foregroundStyle(p.background.color)
        }
        .font(.system(size: 34, weight: .heavy, design: .rounded))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.accent.color))
    }
}
