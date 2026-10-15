import AppKit
import LatticeAX
import LatticeConfig
import LatticeCore

let usage = """
    lattice — keyboard-first tiling window manager for macOS

    USAGE
      Lattice.app                               the menu-bar app (scripts/build-app.sh builds + signs it)
      lattice run [--config FILE] [--verbose] [--apps A,B] [--restore-on-exit]
                                                start tiling; Ctrl-C or the `quit` binding brings parked windows back
                                                (--apps: manage only these apps · --restore-on-exit: also undo tiling)
      lattice config check [FILE]               validate a config file (default ~/.config/lattice/config.yaml)
      lattice config init [--force]             write the documented default config
      lattice config path                       print the config file location
      lattice bindings [--config FILE]          list active key bindings
      lattice session show|forget [--session FILE]
                                                show / delete the saved layout (restored by `lattice run`;
                                                `run --no-restore` skips it, `run --session FILE` uses another file)

    DIAGNOSTICS (week-1 spike tools)
      lattice doctor [--prompt]                 permissions, displays, pending journal
      lattice list [--app NAME] [--all]         windows of regular apps (--all: include non-manageable)
      lattice trace [--app NAME] [--seconds N] [--out FILE]
                                                record AX/workspace events as JSONL until Ctrl-C
      lattice park-test --app NAME [--strategy offscreen|sliver|both] [--corners all|bottomRight,…] [--settle MS]
                                                park each window, measure what the app does, restore
      lattice rescue [--dry-run]                restore journaled windows + pull stranded windows on-screen
    """

// Launched with no arguments from inside Lattice.app (Finder, login item) → the menu-bar app.
if CommandLine.arguments.count == 1, Bundle.main.bundlePath.hasSuffix(".app") {
    MainActor.assumeIsolated { AppMode.run() }
}

guard let command = CommandLine.arguments.dropFirst().first else {
    print(usage)
    exit(0)
}
let args = Array(CommandLine.arguments.dropFirst(2))

@MainActor
func flag(_ name: String) -> Bool { args.contains(name) }
@MainActor
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@MainActor
func requireAccessibility() {
    guard Permissions.accessibility() else {
        fail("""
            Accessibility permission missing.
            Grant it to the app running this command (Terminal / iTerm / Claude) in
            System Settings → Privacy & Security → Accessibility, then re-run.
            `lattice doctor --prompt` opens the system prompt.
            """)
    }
}

switch command {
case "doctor": Commands.doctor(prompt: flag("--prompt"))
case "list": requireAccessibility(); Commands.list(app: option("--app"), all: flag("--all"))
case "trace":
    requireAccessibility()
    Commands.trace(app: option("--app"), seconds: option("--seconds").flatMap(Double.init), out: option("--out"))
case "park-test":
    requireAccessibility()
    guard let app = option("--app") else { fail("park-test needs --app NAME (it moves real windows; be explicit)") }
    let strategies: [ParkingStrategy] =
        switch option("--strategy") ?? "both" {
        case "offscreen": [.offscreen]
        case "sliver": [.sliver]
        case "both": [.offscreen, .sliver]
        case let s: fail("unknown strategy \(s)")
        }
    let corners: [Corner]? =
        switch option("--corners") {
        case nil: nil
        case "all": Corner.allCases
        case let list?: list.split(separator: ",").map { name in
            guard let corner = Corner(rawValue: String(name)) else {
                fail("unknown corner \(name) (bottomRight, bottomLeft, topRight, topLeft)")
            }
            return corner
        }
        }
    Commands.parkTest(app: app, strategies: strategies, corners: corners,
                      settleMs: option("--settle").flatMap(Double.init) ?? 150)
case "rescue": requireAccessibility(); Commands.rescue(dryRun: flag("--dry-run"))
case "app":
    // App mode from a terminal (testing the menu bar / onboarding without the bundle).
    AppMode.run()
case "run":
    requireAccessibility()
    guard InstanceLock.acquire() else { fail("Lattice is already running (the app or another `lattice run`)") }
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even into a file, so our log interleaves with the UI helper's
    let url = option("--config").map { URL(fileURLWithPath: $0) } ?? ConfigLoader.defaultURL
    let settings: Settings
    do { settings = try ConfigLoader.load(from: url) } catch { fail("\(error)") }
    let controller = Controller(
        settings: settings, configURL: url, verbose: flag("--verbose"),
        onlyApps: option("--apps").map { $0.split(separator: ",").map(String.init) },
        restoreOnExit: flag("--restore-on-exit"),
        sessionURL: option("--session").map { URL(fileURLWithPath: $0) } ?? LatticePaths.session,
        restoreSession: !flag("--no-restore"))
    controller.start()
    RunLoop.main.run()
case "config":
    let url = ConfigLoader.defaultURL
    switch args.first {
    case "check":
        let target = args.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? url
        guard FileManager.default.fileExists(atPath: target.path) else { fail("\(target.path) does not exist (built-in defaults are used)") }
        do {
            let s = try ConfigLoader.load(from: target)
            print("✓ \(target.path): \(s.bindings.count) bindings, \(s.rules.count) rules, \(s.workspaces.count) workspaces, layout \(s.defaultLayout.rawValue)")
        } catch { fail("\(error)") }
    case "init":
        if FileManager.default.fileExists(atPath: url.path), !flag("--force") { fail("\(url.path) exists (use --force to overwrite)") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (DefaultConfig.yaml + "\n").write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(url.path)")
        } catch { fail("\(error)") }
    case "path": print(url.path)
    default: fail("usage: lattice config check|init|path")
    }
case "session":
    let url = option("--session").map { URL(fileURLWithPath: $0) } ?? LatticePaths.session
    switch args.first {
    case "show":
        guard let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            fail("no saved session at \(url.path)")
        }
        let when = Date(timeIntervalSince1970: snap.savedAt).formatted(date: .abbreviated, time: .standard)
        print("Saved \(when) · active workspace \(snap.active) · \(snap.windows.count) window(s)")
        for (d, ws) in snap.visible.sorted(by: { $0.key < $1.key }) { print("  display \(d) shows \(ws)") }
        for ws in snap.workspaces.sorted(by: { $0.name < $1.name }) where !ws.windows.isEmpty {
            let groups = ws.groups.isEmpty ? "" : " · \(ws.groups.count) group(s)"
            print("  workspace \(ws.name) [\(ws.layout.rawValue)\(groups)]")
            for id in ws.windows {
                guard let w = snap.windows.first(where: { $0.slot == id }) else { continue }
                print("    \(w.app)\(w.title.map { " — \($0)" } ?? "")\(ws.floating[id] != nil ? " (floating)" : "")")
            }
        }
    case "forget":
        try? FileManager.default.removeItem(at: url)
        print("forgot \(url.path)")
    default: fail("usage: lattice session show|forget [--session FILE]")
    }
case "bindings":
    let url = option("--config").map { URL(fileURLWithPath: $0) } ?? ConfigLoader.defaultURL
    do {
        let s = try ConfigLoader.load(from: url)
        let layout = KeyCodes.currentLayoutMap()
        for b in s.bindings {
            let r = KeyCodes.resolve(b.chord.key, layout: layout)
            let note = r == nil ? "  ⚠️ no key code" : (r!.fallback ? "  (US position)" : "")
            print("\(b.chord.description.padding(toLength: 30, withPad: " ", startingAt: 0)) \(b.command)\(note)")
        }
    } catch { fail("\(error)") }
case "key":
    // Debug/test helper: post a key chord as if typed (goes through every event tap, incl. a running Lattice).
    guard let text = args.first else { fail("usage: lattice key CHORD   e.g. lattice key mod+shift+2") }
    requireAccessibility()
    let mod = (try? ConfigLoader.load().mod) ?? [.ctrl, .alt]
    let chord: KeyChord
    do { chord = try KeyChord.parse(text, mod: mod) } catch { fail("\(error)") }
    guard let code = KeyCodes.resolve(chord.key)?.code else { fail("no key code for \(chord.key)") }
    var flags: CGEventFlags = []
    if chord.modifiers.contains(.cmd) { flags.insert(.maskCommand) }
    if chord.modifiers.contains(.ctrl) { flags.insert(.maskControl) }
    if chord.modifiers.contains(.alt) { flags.insert(.maskAlternate) }
    if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
    // Posting is asynchronous: exiting right away can drop the events, so pause between and after.
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    usleep(100_000)
case "drag":
    // Debug/test helper: a real mouse drag from (x1,y1) to (x2,y2), AX coordinates. `--mod` holds the main modifier.
    guard args.count >= 4, let x1 = Double(args[0]), let y1 = Double(args[1]), let x2 = Double(args[2]), let y2 = Double(args[3]) else {
        fail("usage: lattice drag X1 Y1 X2 Y2 [--mod]")
    }
    requireAccessibility()
    let mod = (try? ConfigLoader.load().mod) ?? [.ctrl, .alt]
    var flags: CGEventFlags = []
    if flag("--mod") {
        if mod.contains(.cmd) { flags.insert(.maskCommand) }
        if mod.contains(.ctrl) { flags.insert(.maskControl) }
        if mod.contains(.alt) { flags.insert(.maskAlternate) }
        if mod.contains(.shift) { flags.insert(.maskShift) }
    }
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType, _ x: Double, _ y: Double) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, x1, y1); usleep(120_000)
    post(.leftMouseDown, x1, y1); usleep(150_000)
    for i in 1...20 {
        let t = Double(i) / 20
        post(.leftMouseDragged, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        usleep(25_000)
    }
    post(.leftMouseUp, x2, y2); usleep(200_000)
case "help", "-h", "--help": print(usage)
default: print(usage); exit(2)
}
