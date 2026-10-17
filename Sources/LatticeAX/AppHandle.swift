import AppKit
import LatticeCore

/// One running app: its AX element plus the worker thread all AX calls for it go through.
public final class AppHandle: @unchecked Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let element: AXElement
    public let worker: AXWorker

    /// Per-call AX messaging timeout. Short on purpose: a WM must not wait seconds for one app.
    public static let messagingTimeout: Float = 0.5

    public init(pid: pid_t, name: String, bundleID: String?) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.element = .application(pid: pid)
        self.worker = AXWorker(label: "\(name)-\(pid)")
        element.setMessagingTimeout(Self.messagingTimeout)
        worker.startAndWait()
    }

    public convenience init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, name: app.localizedName ?? "pid \(app.processIdentifier)", bundleID: app.bundleIdentifier)
    }

    deinit { worker.cancel() }

    /// Regular (Dock-visible) apps — the only ones that own tileable windows.
    @MainActor
    public static func regularApps(matching filter: String? = nil) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid() else { return false }
            guard let filter else { return true }
            let f = filter.lowercased()
            return (app.localizedName?.lowercased().contains(f) ?? false) || (app.bundleIdentifier?.lowercased() == f)
        }
    }

    public struct WindowInfo: Sendable {
        public let element: AXElement
        public let key: String
        public let title: String
        public let frame: Rect?
        public let manageable: Bool
        public let minimized: Bool
        public let fullscreen: Bool
    }

    /// Snapshot of this app's windows, read on the worker.
    public func windows(timeout: TimeInterval = 1.0) throws(AXWorker.SyncError) -> [WindowInfo] {
        let pid = self.pid, app = self.element
        return try worker.sync(timeout: timeout) {
            app.windows.map { w in
                w.setMessagingTimeout(AppHandle.messagingTimeout)
                return WindowInfo(
                    element: w, key: w.key(pid: pid), title: w.title ?? "", frame: w.frame,
                    manageable: w.isManageableWindow, minimized: w.isMinimized, fullscreen: w.isFullscreen
                )
            }
        }
    }

    /// Core snapshot of a window — only for windows a tiler should manage (standard, not minimized,
    /// not native-fullscreen). Call on the worker thread (e.g. inside an observer callback).
    public func managedSnapshot(_ w: AXElement) -> WindowSnapshot? {
        guard w.isManageableWindow, !w.isMinimized, !w.isFullscreen, let frame = w.frame else { return nil }
        return WindowSnapshot(id: WindowID(w.key(pid: pid)), pid: pid, app: name, bundleID: bundleID,
                              title: w.title ?? "", frame: frame, tabs: w.tabTitles)
    }

    /// All managed windows of this app, read on the worker.
    public func managedWindows(timeout: TimeInterval = 1.0) throws(AXWorker.SyncError) -> [(WindowSnapshot, AXElement)] {
        let app = element
        return try worker.sync(timeout: timeout) {
            app.windows.compactMap { w in
                w.setMessagingTimeout(AppHandle.messagingTimeout)
                return self.managedSnapshot(w).map { ($0, w) }
            }
        }
    }

    public struct SetFrameResult: Sendable {
        public let error: AXError
        public let observed: Rect?
        public let latencyMs: Double
    }

    /// Set a window frame and read back what the app actually did.
    /// `timeout` is the budget for the AX calls themselves; `settle` is added on top (it runs inside the worker).
    public func setFrame(
        _ window: AXElement, _ frame: Rect, settle: TimeInterval = 0.15, timeout: TimeInterval = 2.0,
        waitIfBusy: TimeInterval = 0
    ) throws(AXWorker.SyncError) -> SetFrameResult {
        try worker.sync(timeout: settle + timeout, waitIfBusy: waitIfBusy) {
            let start = DispatchTime.now()
            let err = window.setFrame(frame)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            // Apps often apply/clamp asynchronously; give them a moment before reading back.
            Thread.sleep(forTimeInterval: settle)
            return SetFrameResult(error: err, observed: window.frame, latencyMs: ms)
        }
    }
}
