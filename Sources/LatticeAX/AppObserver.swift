import ApplicationServices
import LatticeCore

/// AX notifications for one app, delivered on that app's worker thread.
/// Notifications are *hints* — the controller must still reconcile against a fresh read (docs/idea.md §3).
public final class AppObserver: @unchecked Sendable {
    public typealias Handler = @Sendable (_ notification: String, _ element: AXElement) -> Void

    public let app: AppHandle
    private let handler: Handler
    // Touched only on the worker thread.
    private var observer: AXObserver?
    private var watched = Set<AXElement>()

    static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
    ]
    static let windowNotifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    public init(app: AppHandle, handler: @escaping Handler) {
        self.app = app
        self.handler = handler
    }

    /// Installs the observer on the app's worker run loop. Returns the AX error on failure.
    public func start() throws(AXWorker.SyncError) -> AXError {
        try app.worker.sync(timeout: 2.0) { self.install() }
    }

    public func stop() {
        app.worker.async {
            if let obs = self.observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
            self.observer = nil
            self.watched.removeAll()
        }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func install() -> AXError {
        var obs: AXObserver?
        let err = AXObserverCreate(app.pid, latticeAXCallback, &obs)
        guard err == .success, let obs else { return err }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for n in Self.appNotifications {
            AXObserverAddNotification(obs, app.element.raw, n as CFString, refcon)
        }
        for w in app.element.windows { watch(w) }
        return .success
    }

    private func watch(_ window: AXElement) {
        guard let obs = observer, watched.insert(window).inserted else { return }
        window.setMessagingTimeout(AppHandle.messagingTimeout)
        for n in Self.windowNotifications {
            AXObserverAddNotification(obs, window.raw, n as CFString, refcon)
        }
    }

    fileprivate func handle(_ notification: String, _ element: AXElement) {
        switch notification {
        case kAXWindowCreatedNotification: watch(element)
        case kAXUIElementDestroyedNotification: watched.remove(element)
        default: break
        }
        handler(notification, element)
    }
}

private func latticeAXCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String, AXElement(element))
}
