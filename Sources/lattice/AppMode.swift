import AppKit
import LatticeAX
import LatticeConfig
import LatticeCore
import ServiceManagement
import SwiftUI

/// `Lattice.app`: the same binary, launched with no arguments from inside the bundle (Finder, login item).
/// Menu-bar extra, permission onboarding, start-at-login, logs to ~/Library/Logs/Lattice/lattice.log.
@MainActor
final class AppMode: NSObject, NSApplicationDelegate {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lattice/lattice.log")

    private var controller: Controller?
    private var statusItem: NSStatusItem!
    private var onboarding: NSWindow?
    private var permissionTimer: Timer?
    private let configURL = ConfigLoader.defaultURL

    static func run() -> Never {
        redirectLogs()
        let app = NSApplication.shared
        let delegate = AppMode()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon
        app.run()
        exit(0)
    }

    /// stdout/stderr (ours and the UI helper's, which inherits them) → log file.
    static func redirectLogs() {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the log bounded: start fresh when it passes 5 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        freopen(logURL.path, "a", stdout)
        freopen(logURL.path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("──── Lattice.app started \(Date().formatted(date: .numeric, time: .standard)) ────")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard InstanceLock.acquire() else {
            let alert = NSAlert()
            alert.messageText = "Lattice is already running"
            alert.informativeText = "Another Lattice (the app or `lattice run` in a terminal) is managing windows. Quit it first."
            alert.runModal()
            exit(1)
        }
        buildMenu()
        if Permissions.accessibility() {
            startController()
        } else {
            showOnboarding()
        }
    }

    // MARK: - Controller

    func startController() {
        guard controller == nil else { return }
        let settings: LatticeCore.Settings
        do {
            settings = try ConfigLoader.load(from: configURL)
        } catch {
            // A broken config must not leave the user without a WM: run on defaults and say why.
            print("✗ config error — running with built-in defaults\n    \(error)")
            settings = ConfigLoader.defaults
            let alert = NSAlert()
            alert.messageText = "Your Lattice config has an error"
            alert.informativeText = "\(error)\n\nLattice is running with the built-in defaults. Fix the file and choose Reload Config."
            alert.runModal()
        }
        let c = Controller(settings: settings, configURL: configURL, verbose: false, appMode: true)
        controller = c
        c.start()
        updateMenu()
    }

    // MARK: - Menu bar

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Lattice")
        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()
        let running = controller != nil
        let title = NSMenuItem(title: running ? "Lattice — tiling" : "Lattice — waiting for permission", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Reload Config", #selector(reloadConfig), "r", enabled: running))
        menu.addItem(item("Open Config", #selector(openConfig), ","))
        menu.addItem(item("Restore Saved Layout", #selector(restoreSession), "", enabled: running))
        menu.addItem(.separator())
        let login = item("Start at Login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Permissions…", #selector(openOnboarding), ""))
        menu.addItem(item("Show Log", #selector(showLog), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Lattice", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    @objc func reloadConfig() { controller?.command(.reload) }

    @objc func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (DefaultConfig.yaml + "\n").write(to: configURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc func restoreSession() { controller?.command(.session(.restore)) }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nIf macOS asks, allow Lattice in System Settings → General → Login Items."
            alert.runModal()
        }
        updateMenu()
    }

    @objc func showLog() { NSWorkspace.shared.open(Self.logURL) }

    @objc func openOnboarding() { showOnboarding() }

    @objc func quit() {
        if let controller { controller.shutdown() }   // restores parked windows, saves the session, exits
        exit(0)
    }

    /// Quit from outside (logout/shutdown, `brew upgrade`/`uninstall`, `osascript … to quit`): same as ▦ → Quit,
    /// so windows of hidden workspaces are never left parked in the corner.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit()
        return .terminateNow   // not reached: quit() exits
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Welcome to Lattice"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: OnboardingModel.shared))
            w.center()
            onboarding = w
        }
        NSApp.activate()
        onboarding?.makeKeyAndOrderFront(nil)
        OnboardingModel.shared.refresh()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                OnboardingModel.shared.refresh()
                if OnboardingModel.shared.accessibility, self.controller == nil {
                    self.startController()
                    self.onboarding?.close()
                    self.permissionTimer?.invalidate()
                }
            }
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var macTiling: [String] = []

    func refresh() {
        accessibility = Permissions.accessibility()
        inputMonitoring = Permissions.inputMonitoring()
        macTiling = MacTiling.enabled
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lattice needs one permission").font(.title2.weight(.semibold))
            Text("macOS asks you to approve it once. Lattice starts tiling as soon as Accessibility is on — this window updates by itself.")
                .foregroundStyle(.secondary)
            row("Accessibility", "Move and resize windows, and react to your keys.", model.accessibility,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                _ = Permissions.accessibility(prompt: true)
            }
            row("Input Monitoring (optional)",
                "Not needed — Lattice's shortcuts work with Accessibility alone. Grant it only if shortcuts ever stop working.",
                model.inputMonitoring,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                _ = Permissions.inputMonitoring(prompt: true)
            }
            if !model.macTiling.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS window tiling is on").font(.headline)
                        Text("It snaps windows you drag (screen edges, ⌥-drag) before Lattice can place them. Recommended: off.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Turn off macOS tiling") { MacTiling.disable(); model.refresh() }.padding(.top, 2)
                    }
                }
            }
            Spacer()
            Text("Find Lattice in the menu bar (▦) for config, start at login and quit.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520, height: 440)
    }

    func row(_ name: String, _ why: String, _ ok: Bool, _ settingsURL: String, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2).foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary)
                if !ok {
                    HStack {
                        Button("Ask macOS") { request() }
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: settingsURL)!) }
                    }.padding(.top, 2)
                }
            }
        }
    }
}

/// One Lattice at a time (app or `lattice run`): an advisory lock on a file in Application Support.
enum InstanceLock {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let url = LatticePaths.supportDir.appendingPathComponent("lattice.lock")
        try? FileManager.default.createDirectory(at: LatticePaths.supportDir, withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // can't lock: don't block the user
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
