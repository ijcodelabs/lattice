import AppKit
import LatticeAX
import LatticeConfig
import LatticeCore

/// `lattice run`: wires the AX edge, hotkeys and config to the pure `Engine`, and executes its effects.
///
/// Threading: everything here is main-actor. AX calls go to each app's `AXWorker` (async for effects,
/// so a hung app never blocks the main thread); AX notifications hop back to main as engine events.
@MainActor
final class Controller {
    private var engine: Engine
    private let configURL: URL
    private let verbose: Bool
    /// Manage only these apps (lower-cased names); nil = all regular apps.
    private let onlyApps: Set<String>?
    /// On exit, also put tiled windows back to the frames they had when Lattice started.
    private let restoreOnExit: Bool
    private var apps: [pid_t: AppHandle] = [:]
    private var observers: [pid_t: AppObserver] = [:]
    private var elements: [WindowID: AXElement] = [:]
    private var hotkeys: HotkeyTap!
    private var router = KeyRouter()
    private var ui: UIBridge!
    private var paletteItems: [String: PaletteItem] = [:]
    // What the UI helper last got — only changes are sent.
    private var sentTheme: Theme?
    private var sentBars: [BarModel]?
    private var sentStrips: [GroupStrip]?
    private var sentState: BarState?
    private var sentBorder: Rect??
    private var themesWatcher: DispatchSourceFileSystemObject?
    private var configFileWatcher: DispatchSourceFileSystemObject?
    private var modeTimer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var reconcileTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastJournal: [WindowID: Rect] = [:]
    private var shuttingDown = false
    /// Session file (saved layout) and whether to restore it at start.
    private let sessionURL: URL
    private let restoreSession: Bool
    private var saveTimer: Timer?
    /// Inside Lattice.app: the app delegate owns NSApp (menu-bar extra); don't change its activation policy.
    private let appMode: Bool
    private var lastSaved: Data?

    init(settings: Settings, configURL: URL, verbose: Bool, onlyApps: [String]? = nil, restoreOnExit: Bool = false,
         sessionURL: URL = LatticePaths.session, restoreSession: Bool = true, appMode: Bool = false) {
        self.appMode = appMode
        self.sessionURL = sessionURL
        self.restoreSession = restoreSession
        self.configURL = configURL
        self.verbose = verbose
        self.onlyApps = onlyApps.map { Set($0.map { $0.lowercased() }) }
        self.restoreOnExit = restoreOnExit
        self.engine = Engine(settings: settings, displays: Displays.current())
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        print("[\(Self.clock.string(from: Date()))] \(message)")
    }

    // MARK: - Lifecycle

    func start() {
        // A previous run may have crashed with windows parked.
        JournalRestore.run(dryRun: false)

        if !appMode { NSApplication.shared.setActivationPolicy(.prohibited) }

        ui = UIBridge(onReply: { [weak self] in self?.uiReply($0) }, log: { [weak self] in self?.log($0) })
        ui.start()

        hotkeys = HotkeyTap { [weak self] chord in self?.route(chord) ?? false }
        hotkeys.onMouse = { [weak self] down, point, mods in self?.mouse(down: down, at: point, mods: mods) }
        for p in HotkeyTap.problems(allBindings(engine.settings)) { log("⚠️ \(p)") }
        guard hotkeys.install() else {
            fail("could not install the keyboard event tap — Accessibility permission missing for this terminal?")
        }
        if KeyCodes.secureInputEnabled { log("⚠️ Secure Input is on (a password field or terminal has it) — hotkeys are blocked until it's off") }

        // Discover existing windows in one batch so the first layout is computed once.
        // A saved session goes first: the discovered windows are then matched into it.
        var events: [Event] = []
        if restoreSession, engine.settings.session.restore, let snap = loadSession() {
            events.append(.restoreSession(snap, until: now + engine.settings.session.grace))
        }
        for app in AppHandle.regularApps() { events += attach(app, scan: true) }
        if let front = NSWorkspace.shared.frontmostApplication, let handle = apps[front.processIdentifier],
           let id = try? handle.worker.sync(timeout: 0.5, { handle.element.focusedWindow.map { WindowID($0.key(pid: handle.pid)) } }) {
            events.append(.windowFocused(id))
        }
        dispatch(events)
        log("managing \(engine.windows.count) window(s) on workspace \(engine.active) · layout \(engine.activeWorkspace.layout.rawValue) · \(engine.settings.bindings.count) bindings")
        log("config: \(FileManager.default.fileExists(atPath: configURL.path) ? configURL.path : "built-in defaults (run `lattice config init` to customise)")")

        observeWorkspace()
        watchConfig()
        installSignalHandlers()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        modeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.router.expire(settings: self.engine.settings, now: self.now) else { return }
                self.log("mode timed out")
                self.ui.send(.hud(nil))
                self.syncUI()
            }
        }
    }

    /// Put every parked window back on screen, then exit.
    func shutdown(code: Int32 = 0) -> Never {
        shuttingDown = true
        log("shutting down — restoring \(engine.parked.count) parked window(s)")
        saveSession()   // the layout as it is now — before windows are put back for the desktop
        hotkeys?.uninstall()
        ui?.stop()
        var restores = engine.restoreEffects()
        if restoreOnExit {
            restores = engine.windows.values.sorted { $0.id < $1.id }.map { .setFrame($0.id, $0.frame) }
        }
        for case let .setFrame(id, r) in restores {
            guard let el = elements[id], let pid = engine.windows[id]?.pid, let app = apps[pid] else { continue }
            _ = try? app.worker.sync(timeout: 1, waitIfBusy: 1) { el.setFrame(r) }
        }
        try? ParkJournal().save(to: LatticePaths.journal)
        exit(code)
    }

    // MARK: - Engine bridge

    func dispatch(_ events: [Event]) {
        guard !events.isEmpty, !shuttingDown else { return }
        let effects = engine.handle(events, now: now)
        execute(effects)
        persistJournal()
        syncUI()
        scheduleSave()
    }

    // MARK: - Session

    /// Save ~1.5 s after the last change (debounced), so a crash or power loss keeps the layout.
    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    func saveSession() {
        guard let snap = engine.snapshot(savedAt: Date().timeIntervalSince1970) else { return }   // mid-restore: don't
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        // Compare without the timestamp so an unchanged layout isn't rewritten every 1.5 s.
        var stable = snap
        stable.savedAt = 0
        guard let key = try? enc.encode(stable), key != lastSaved, let data = try? enc.encode(snap) else { return }
        do {
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: sessionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)   // titles are private
            lastSaved = key
            if verbose { log("session saved (\(snap.windows.count) windows)") }
        } catch {
            log("⚠️ session save failed: \(error)")
        }
    }

    func loadSession() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        do {
            let snap = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            guard snap.version == SessionSnapshot.currentVersion else {
                log("⚠️ session file is version \(snap.version), expected \(SessionSnapshot.currentVersion) — ignored")
                return nil
            }
            return snap
        } catch {
            log("⚠️ session file unreadable — ignored (\(error.localizedDescription))")
            return nil
        }
    }

    /// Send the UI helper whatever changed: theme, bar placement, bar state, focus border.
    /// `force` re-sends everything (helper (re)started).
    func syncUI(force: Bool = false) {
        guard let ui else { return }
        if force || sentTheme != engine.settings.theme {
            sentTheme = engine.settings.theme
            ui.send(.theme(engine.settings.theme))
        }
        let bars = engine.bars
        if force || sentBars != bars {
            sentBars = bars
            ui.send(.bars(bars))
        }
        let strips = engine.groupStrips
        if force || sentStrips != strips {
            sentStrips = strips
            ui.send(.groups(strips))
        }
        let state = BarState.from(engine, mode: router.mode)
        if force || sentState != state {
            sentState = state
            ui.send(.state(state))
        }
        let border = engine.focusBorderFrame
        if force || sentBorder != .some(border) {
            sentBorder = .some(border)
            ui.send(.border(border))
        }
    }

    // MARK: - Keys

    /// Called synchronously from the event tap: decide now whether to swallow; run commands right after.
    func route(_ chord: KeyChord) -> Bool {
        let r = router.handle(chord, settings: engine.settings, now: now)
        if r.modeChanged {
            ui.send(.hints(router.hint?.badges ?? []))
            ui.send(.hud(router.hud(settings: engine.settings)))
            syncUI()   // the bar's mode widget
            if let m = router.mode { log("mode \(m)") }
        }
        if !r.commands.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { for c in r.commands { self?.command(c) } }
            }
        }
        return r.consumed
    }

    // MARK: - Mouse

    private var dragMods: KeyChord.Modifiers = []

    /// Button released: after the app's last move/resize notifications have arrived, any on-screen window
    /// whose real frame differs from what we placed was dragged by the user — let the engine decide.
    func mouse(down: Bool, at point: Point, mods: KeyChord.Modifiers) {
        if down { dragMods = mods; return }
        let float = !engine.settings.mod.isEmpty && dragMods == engine.settings.mod
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let onScreen = self.engine.visibleFrames()
                let dragged = self.engine.windows.keys.sorted().filter { id in
                    guard onScreen[id] != nil, let o = self.engine.observed[id], let s = self.engine.sent[id] else { return false }
                    return !o.approximatelyEquals(s, tolerance: 4)
                }
                for id in dragged {
                    guard let frame = self.engine.observed[id] else { continue }
                    if self.verbose { self.log("drag \(self.engine.windows[id]?.app ?? "?") → \(frame) at \(point)\(float ? " (float)" : "")") }
                    self.dispatch([.windowDragged(id, frame: frame, cursor: point, float: float)])
                }
            }
        }
    }

    func allBindings(_ s: Settings) -> [Binding] { s.bindings + s.modes.values.flatMap(\.bindings) }

    func command(_ c: Command) {
        log("⌨︎ \(c)")
        dispatch([.command(c)])
    }

    func execute(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .setFrame(id, r):
                guard let el = elements[id], let pid = engine.windows[id]?.pid, let app = apps[pid] else { continue }
                if let stuck = app.worker.stuckFor, stuck > 1 {
                    log("⚠️ \(app.name) not responding (\(Int(stuck))s) — skipped move")
                    continue
                }
                app.worker.async { el.setFrame(r) }
            case let .focus(id):
                guard let el = elements[id], let pid = engine.windows[id]?.pid, let app = apps[pid] else { continue }
                app.worker.async { el.raise() }
                NSRunningApplication(processIdentifier: pid)?.activate()
            case let .exec(cmd):
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd]
                do { try p.run() } catch { log("⚠️ exec failed: \(error)") }
            case .reload:
                reloadConfig(reason: "reload command")
            case .quit:
                shutdown()
            case .openPalette:
                openPalette()
            case let .log(m):
                log(m)
            case let .startHints(action, targets):
                router.startHints(action, targets)
                ui.send(.hud(nil))
                ui.send(.hints(router.hint?.badges ?? []))
            case .saveSession:
                lastSaved = nil
                saveSession()
                log("session saved → \(sessionURL.path)")
            case .loadSession:
                if let snap = loadSession() {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.dispatch([.restoreSession(snap, until: self.now + self.engine.settings.session.grace)])
                        }
                    }
                } else {
                    log("no saved session at \(sessionURL.path)")
                }
            case .forgetSession:
                try? FileManager.default.removeItem(at: sessionURL)
                lastSaved = nil
                log("session forgotten")
            }
        }
    }

    /// Persist parked windows' on-screen frames so `lattice rescue` / the next start can restore them.
    func persistJournal() {
        guard engine.parked != lastJournal else { return }
        lastJournal = engine.parked
        var journal = ParkJournal()
        for (id, r) in engine.parked {
            guard let w = engine.windows[id] else { continue }
            journal.record(.init(pid: w.pid, app: w.app, title: w.title, windowKey: id.raw, original: r))
        }
        do { try journal.save(to: LatticePaths.journal) } catch { log("⚠️ journal write failed: \(error)") }
    }

    // MARK: - Apps & windows

    /// Start observing an app; optionally scan its windows now. Returns `windowAdded` events.
    @discardableResult
    func attach(_ running: NSRunningApplication, scan: Bool) -> [Event] {
        let pid = running.processIdentifier
        guard apps[pid] == nil else { return [] }
        if let onlyApps, !onlyApps.contains((running.localizedName ?? "").lowercased()) { return [] }
        let handle = AppHandle(running)
        apps[pid] = handle

        let observer = AppObserver(app: handle) { [weak self] notification, element in
            // Worker thread: read what we need from AX here, then hop to main with plain values.
            let id = WindowID(element.key(pid: pid))
            let event: Event?
            switch notification {
            case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
                event = handle.managedSnapshot(element).map(Event.windowAdded)
            case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
                event = .windowRemoved(id)
            case kAXFocusedWindowChangedNotification:
                event = handle.element.focusedWindow.map { .windowFocused(WindowID($0.key(pid: pid))) }
            case kAXWindowMovedNotification, kAXWindowResizedNotification:
                event = element.frame.map { .windowFrameObserved(id, $0) }
            default:
                event = nil
            }
            guard let event else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.axEvent(event, element: element, notification: notification) }
            }
        }
        if (try? observer.start()) == .success { observers[pid] = observer }

        guard scan else { return [] }
        guard let windows = try? handle.managedWindows() else {
            log("⚠️ \(handle.name) didn't answer in time — will retry")
            return []
        }
        for (_, el) in windows { elements[WindowID(el.key(pid: pid))] = el }
        return windows.map { .windowAdded($0.0) }
    }

    func axEvent(_ event: Event, element: AXElement, notification: String) {
        if verbose { log("ax \(notification) \(event)") }
        switch event {
        case let .windowAdded(snap):
            elements[snap.id] = element
            log("+ \(snap.app) “\(snap.title.prefix(40))”")
        case let .windowRemoved(id):
            guard engine.windows[id] != nil else { return }
            log("− \(engine.windows[id]?.app ?? "?")")
        default: break
        }
        dispatch([event])
        if case let .windowRemoved(id) = event { elements[id] = nil }
    }

    func detach(pid: pid_t) {
        observers.removeValue(forKey: pid)?.stop()
        apps[pid] = nil
        let gone = engine.windows.values.filter { $0.pid == pid }.map(\.id)
        dispatch(gone.map(Event.windowRemoved))
        for id in gone { elements[id] = nil }
    }

    /// AX notifications are hints (docs/idea.md §3): periodically re-read every app's windows and fix drift.
    func reconcile() {
        for (pid, handle) in apps {
            handle.worker.async {
                let found = handle.element.windows.compactMap { w in handle.managedSnapshot(w).map { ($0, w) } }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.applyScan(pid: pid, found: found) }
                }
            }
        }
    }

    func applyScan(pid: pid_t, found: [(WindowSnapshot, AXElement)]) {
        guard apps[pid] != nil else { return }
        let known = Set(engine.windows.values.filter { $0.pid == pid }.map(\.id))
        let seen = Set(found.map(\.0.id))
        var events: [Event] = []
        for (snap, el) in found where !known.contains(snap.id) {
            elements[snap.id] = el
            events.append(.windowAdded(snap))
            log("+ \(snap.app) “\(snap.title.prefix(40))” (reconcile)")
        }
        // Titles change (saved document, new browser tab): refresh them for the palette, bar and session.
        for (snap, _) in found where known.contains(snap.id) && engine.windows[snap.id]?.title != snap.title {
            events.append(.windowAdded(snap))
        }
        dispatch(events)

        // Not listed ≠ closed: on another macOS Space an app stops listing its windows (memory/gotchas.md #33).
        // Ask each missing window whether it still exists before forgetting it.
        let missing = known.subtracting(seen)
        guard !missing.isEmpty, let handle = apps[pid] else { return }
        let checks = missing.map { id in (id, elements[id]) }
        handle.worker.async {
            let gone = checks.filter { $0.1.map { !$0.exists } ?? true }.map(\.0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let stillKnown = gone.filter { self.engine.windows[$0] != nil }
                    for id in stillKnown { self.log("− \(self.engine.windows[id]?.app ?? "?") (reconcile)") }
                    self.dispatch(stillKnown.map(Event.windowRemoved))
                    for id in stillKnown { self.elements[id] = nil }
                }
            }
        }
    }

    func observeWorkspace() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, center: NotificationCenter = ws, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app, app.activationPolicy == .regular else { return }
            attach(app, scan: false)
            // Windows created before the observer attached are picked up by a quick scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            detach(pid: app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app, let handle = apps[app.processIdentifier] else { return }
            handle.worker.async {
                guard let w = handle.element.focusedWindow else { return }
                let id = WindowID(w.key(pid: handle.pid))
                DispatchQueue.main.async { MainActor.assumeIsolated { self.dispatch([.windowFocused(id)]) } }
            }
        }
        on(Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
           center: DistributedNotificationCenter.default()) { [weak self] _ in
            self?.hotkeys.refreshLayout()
            self?.log("keyboard layout changed — key map refreshed")
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.log("macOS Space changed — Lattice manages one Space per display; windows on other Spaces are kept, not tiled anew")
        }
        on(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] _ in
            guard let self else { return }
            log("displays changed")
            dispatch([.displaysChanged(Displays.current())])
        }
    }

    // MARK: - UI

    func openPalette() {
        let items = Palette.items(for: engine)
        paletteItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        ui.send(.openPalette(items))
    }

    func uiReply(_ reply: UIReply) {
        switch reply {
        case let .ready(version):
            if version != UIProtocol.version { log("⚠️ UI helper speaks protocol v\(version), expected v\(UIProtocol.version)") }
            syncUI(force: true)
        case let .chose(id):
            guard let item = paletteItems[id], let c = try? Command.parse(item.command) else { return }
            log("palette → \(item.title)")
            command(c)
            refocusAfterPalette(unless: c)
        case .cancelled:
            refocusAfterPalette(unless: nil)
        case let .run(text):
            // From the bar (e.g. clicking a workspace). Parsed like any binding; garbage is logged, not run.
            do { command(try Command.parse(text)) } catch { log("⚠️ UI asked for invalid command '\(text)': \(error)") }
        case let .log(m):
            log("[ui] \(m)")
        }
    }

    /// The palette took keyboard focus; hand it back to the focused window unless the command did.
    func refocusAfterPalette(unless c: Command?) {
        if case .focusWindow = c { return }
        if case .quit = c { return }
        if let f = engine.focused { execute([.focus(f)]) }
    }

    // MARK: - Config

    /// Watch three things (memory/gotchas.md #16): the config directory (editors that save via
    /// temp-file + rename), the config file itself (in-place writes: `>>`, vim backupcopy=yes, …),
    /// and the themes directory.
    func watchConfig() {
        configWatcher = watch(configURL.deletingLastPathComponent())
        themesWatcher = watch(ConfigLoader.themesDir(for: configURL))
        rewatchConfigFile()
    }

    /// (Re)attach to the config file. After a rename/delete the old descriptor points at a dead inode,
    /// so this runs again on every reload.
    func rewatchConfigFile() {
        configFileWatcher?.cancel()
        configFileWatcher = watch(configURL, mask: [.write, .extend, .delete, .rename])
    }

    /// Reload on any change to `path` (debounced). Nil when it doesn't exist.
    func watch(_ path: URL, mask: DispatchSource.FileSystemEvent = [.write, .rename, .delete]) -> DispatchSourceFileSystemObject? {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.reloadPending else { return }
                self.reloadPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated {
                        self.reloadPending = false
                        self.reloadConfig(reason: "config changed")
                    }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    func reloadConfig(reason: String) {
        rewatchConfigFile()
        do {
            let s = try ConfigLoader.load(from: configURL)
            guard s != engine.settings else { return }
            for p in HotkeyTap.problems(allBindings(s)) { log("⚠️ \(p)") }
            router.reset()
            ui.send(.hud(nil))
            dispatch([.settingsChanged(s)])
            log("✓ config reloaded (\(reason))")
        } catch {
            // Keep the last good config.
            log("✗ config error — keeping previous config\n    \(error)")
        }
    }

    func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.shutdown() } }
            src.resume()
            signalSources.append(src)
        }
    }
}
