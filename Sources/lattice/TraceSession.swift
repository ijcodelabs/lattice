import AppKit
import LatticeAX
import LatticeCore

/// Live AX + workspace event recording for `lattice trace`.
@MainActor
final class TraceSession {
    private let writer: TraceWriter
    private let filter: String?
    private var observers: [pid_t: AppObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let counts = Counter()

    init(writer: TraceWriter, filter: String?) {
        self.writer = writer
        self.filter = filter
    }

    var summary: String {
        let c = counts.snapshot.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        return c.isEmpty ? "No events." : "Events: " + c.joined(separator: ", ")
    }

    func start() {
        for app in AppHandle.regularApps(matching: filter) { attach(app) }

        let ws = NSWorkspace.shared.notificationCenter
        // Only the app (if any) crosses into the main-actor body; Notification itself isn't Sendable.
        func on(_ name: Notification.Name, center: NotificationCenter = ws, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            emit(.appLaunched, pid: app.processIdentifier, app: app.localizedName)
            if AppHandle.regularApps(matching: filter).contains(app) { attach(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            emit(.appTerminated, pid: app.processIdentifier, app: app.localizedName)
            observers.removeValue(forKey: app.processIdentifier)?.stop()
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            emit(.appActivated, pid: app.processIdentifier, app: app.localizedName)
        }
        on(NSWorkspace.willSleepNotification) { [weak self] _ in self?.emit(.sleep) }
        on(NSWorkspace.didWakeNotification) { [weak self] _ in self?.emit(.wake) }
        on(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] _ in
            let names = Displays.current().map { "\($0.name) \($0.frame)" }.joined(separator: "; ")
            self?.emit(.displaysChanged, detail: names)
        }
        // Screen-change notifications need an NSApplication instance (no UI, no Dock icon).
        NSApplication.shared.setActivationPolicy(.prohibited)

        emit(.note, detail: "trace started; displays: " + Displays.current().map { "\($0.name) \($0.frame)" }.joined(separator: "; "))
    }

    func stop() {
        for o in observers.values { o.stop() }
        observers.removeAll()
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }

    private func attach(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        guard observers[pid] == nil else { return }
        let handle = AppHandle(running)
        let writer = self.writer, counts = self.counts
        let observer = AppObserver(app: handle) { notification, element in
            // Runs on the app's worker thread — AX reads are safe here.
            let kind = Self.kind(for: notification)
            let event = TraceEvent(
                t: writer.elapsed, kind: kind, pid: pid, app: handle.name, window: element.key(pid: pid),
                title: element.title, frame: element.frame, detail: kind == .note ? notification : nil
            )
            writer.write(event)
            counts.bump(kind.rawValue)
            print(String(format: "%8.3f  %-16@ %@ %@", event.t, kind.rawValue as NSString, handle.name as NSString,
                         (event.frame?.description ?? "") as NSString))
        }
        do {
            let err = try observer.start()
            if err == .success {
                observers[pid] = observer
            } else {
                emit(.axError, pid: pid, app: handle.name, detail: "AXObserverCreate: \(err.name)")
            }
        } catch {
            emit(.axTimeout, pid: pid, app: handle.name, detail: "\(error)")
        }
    }

    private func emit(_ kind: TraceEvent.Kind, pid: pid_t? = nil, app: String? = nil, detail: String? = nil) {
        writer.write(TraceEvent(t: writer.elapsed, kind: kind, pid: pid, app: app, detail: detail))
        counts.bump(kind.rawValue)
        print(String(format: "%8.3f  %-16@ %@ %@", writer.elapsed, kind.rawValue as NSString, (app ?? "") as NSString,
                     (detail ?? "") as NSString))
    }

    nonisolated static func kind(for notification: String) -> TraceEvent.Kind {
        switch notification {
        case kAXWindowCreatedNotification: .windowCreated
        case kAXUIElementDestroyedNotification: .windowDestroyed
        case kAXWindowMovedNotification: .windowMoved
        case kAXWindowResizedNotification: .windowResized
        case kAXFocusedWindowChangedNotification: .windowFocused
        case kAXWindowMiniaturizedNotification: .windowMinimized
        case kAXWindowDeminiaturizedNotification: .windowDeminimized
        default: .note
        }
    }
}

/// Thread-safe event counter (observers fire on worker threads).
final class Counter: @unchecked Sendable {
    private var values: [String: Int] = [:]
    private let lock = NSLock()
    func bump(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
    var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return values }
}
