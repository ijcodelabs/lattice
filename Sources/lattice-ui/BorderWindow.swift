import AppKit
import LatticeCore
import SwiftUI

/// Focus border: a transparent, click-through panel just outside the focused window, drawing a rounded
/// stroke in the theme's border colour. No private APIs — it is an ordinary window.
@MainActor
final class BorderWindow {
    private let panel: NSPanel
    private let store: ThemeStore
    private var target: Rect?

    init(store: ThemeStore) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]   // stay on Lattice's Space (not every macOS Space)
        panel.contentView = NSHostingView(rootView: BorderView(store: store))
    }

    func show(_ frame: Rect?) {
        target = frame
        guard let frame, store.theme.borderWidth > 0 else { panel.orderOut(nil); return }
        let w = store.theme.borderWidth
        let r = cocoaRect(frame).insetBy(dx: -w, dy: -w)
        panel.setFrame(r, display: true)
        panel.orderFrontRegardless()
    }

    /// Theme changed (width may differ): re-place around the same window.
    func refresh() { show(target) }
}

struct BorderView: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        let w = store.theme.borderWidth
        RoundedRectangle(cornerRadius: store.theme.borderRadius + w / 2, style: .continuous)
            .strokeBorder(store.palette.border.color, lineWidth: w)
    }
}
