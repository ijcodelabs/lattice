import AppKit
import LatticeAX
import LatticeCore

@MainActor
enum Commands {
    // MARK: - doctor

    static func doctor(prompt: Bool) {
        let ax = Permissions.accessibility(prompt: prompt)
        let im = Permissions.inputMonitoring()
        print("Accessibility     \(ax ? "✅ granted" : "❌ missing — System Settings → Privacy & Security → Accessibility")")
        print("Input Monitoring  \(im ? "✅ granted" : "⚪️ not granted — not needed (Lattice's key hook is covered by Accessibility)")")
        print("Post events       \(CGPreflightPostEventAccess() ? "✅ granted" : "⚪️ not granted (only `lattice key` needs it)")")
        print("Secure Input      \(KeyCodes.secureInputEnabled ? "⚠️ ON — hotkeys are blocked right now" : "off")")
        let tiling = MacTiling.enabled
        print("macOS tiling      \(tiling.isEmpty ? "off ✅" : "⚠️ on — it snaps windows you drag, fighting Lattice")")
        for t in tiling { print("                    · \(t)  (System Settings → Desktop & Dock → Windows)") }
        print("Responsible app   TCC grants apply to the app that launched this CLI (your terminal), not to `lattice`.")
        print("")
        print("Displays (AX coordinates, origin top-left of primary):")
        for d in Displays.current() {
            print("  \(d.isPrimary ? "★" : " ") #\(d.id) \(d.name)  frame \(d.frame)  visible \(d.visibleFrame)")
        }
        let journal = ParkJournal.load(from: LatticePaths.journal)
        print("")
        print(journal.entries.isEmpty
            ? "Park journal      empty (no windows left parked)"
            : "Park journal      ⚠️ \(journal.entries.count) parked window(s) — run `lattice rescue`")
    }

    // MARK: - list

    static func list(app filter: String?, all: Bool) {
        let displays = Displays.current()
        var rows: [[String]] = [["APP", "PID", "WINDOW", "FRAME", "DISPLAY", "FLAGS"]]
        for running in AppHandle.regularApps(matching: filter) {
            let handle = AppHandle(running)
            do {
                for w in try handle.windows() where all || w.manageable {
                    var flags: [String] = []
                    if w.manageable { flags.append("tile") }
                    if w.minimized { flags.append("min") }
                    if w.fullscreen { flags.append("fs") }
                    if let f = w.frame, Rescue.isStranded(f, displays: displays) { flags.append("STRANDED") }
                    rows.append([
                        handle.name, "\(handle.pid)", w.title.truncated(40), w.frame?.description ?? "?",
                        w.frame?.dominantDisplay(in: displays)?.name ?? "—", flags.joined(separator: ","),
                    ])
                }
            } catch {
                rows.append([handle.name, "\(handle.pid)", "⚠️ \(error)", "", "", ""])
            }
        }
        printTable(rows)
    }

    // MARK: - trace

    static func trace(app filter: String?, seconds: Double?, out: String?) {
        let url = out.map { URL(fileURLWithPath: $0) }
            ?? LatticePaths.traces.appendingPathComponent("trace-\(timestamp()).jsonl")
        let writer: TraceWriter
        do { writer = try TraceWriter(url: url) } catch { fail("cannot open \(url.path): \(error)") }

        let session = TraceSession(writer: writer, filter: filter)
        session.start()
        print("Tracing to \(url.path)")
        print(seconds.map { "Recording for \(Int($0))s…" } ?? "Recording — Ctrl-C to stop.")

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        nonisolated(unsafe) var stop = false
        sigint.setEventHandler { stop = true }
        sigint.resume()

        let deadline = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        while !stop, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.25)))
        }
        session.stop()
        writer.close()
        print("\nStopped. \(session.summary)")
        print("Trace: \(url.path)")
    }

    // MARK: - park-test

    static func parkTest(app filter: String, strategies: [ParkingStrategy], corners: [Corner]?, settleMs: Double) {
        let displays = Displays.current()
        guard let primary = displays.first(where: \.isPrimary) else { fail("no displays") }
        let writer = try? TraceWriter(url: LatticePaths.traces.appendingPathComponent("park-test-\(timestamp()).jsonl"))
        let settle = settleMs / 1000

        // Ctrl-C mid-test must never leave windows parked.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler {
            print("\nInterrupted — restoring journaled windows…")
            JournalRestore.run(dryRun: false)
            exit(130)
        }
        sigint.resume()

        let apps = AppHandle.regularApps(matching: filter)
        if apps.isEmpty { fail("no running regular app matches '\(filter)'") }

        var rows: [[String]] = [["APP", "WINDOW", "STRATEGY", "CORNER", "OUTCOME", "OBSERVED", "VISIBLE", "HIDDEN", "SET ms", "RESTORED"]]
        var stats: [String: [FrameOutcome]] = [:]
        var hiddenCount: [String: Int] = [:]
        var latencies: [Double] = []

        for running in apps {
            let handle = AppHandle(running)
            let windows: [AppHandle.WindowInfo]
            do { windows = try handle.windows().filter { $0.manageable && !$0.minimized && !$0.fullscreen } } catch {
                rows.append([handle.name, "⚠️ \(error)"])
                continue
            }
            if windows.isEmpty { rows.append([handle.name, "(no manageable windows)"]) }

            for w in windows {
                guard let original = w.frame else { continue }
                let home = original.dominantDisplay(in: displays) ?? primary

                // Write-ahead: journal BEFORE moving anything.
                var journal = ParkJournal.load(from: LatticePaths.journal)
                journal.record(.init(pid: handle.pid, app: handle.name, title: w.title, windowKey: w.key, original: original))
                try? journal.save(to: LatticePaths.journal)

                var allRestored = true
                // nil corners = production behaviour (first safe corner); otherwise test each corner on its own.
                let attempts: [(ParkingStrategy, [Corner])] = strategies.flatMap { s in
                    corners.map { $0.map { (s, [$0]) } } ?? [(s, Parking.cornerPreference)]
                }
                for (strategy, cornerSet) in attempts {
                    guard let plan = Parking.plan(
                        size: original.size, home: home, displays: displays, strategy: strategy, corners: cornerSet
                    ) else {
                        rows.append([handle.name, w.title.truncated(28), strategy.rawValue, cornerSet.count == 1 ? cornerSet[0].rawValue : "—",
                                     "no safe corner"])
                        continue
                    }
                    var outcome = FrameOutcome.failed
                    var observed = "?", visible = "?", hidden = "?", latency = "?", restored = "?"
                    do {
                        let r = try handle.setFrame(w.element, plan.frame, settle: settle)
                        outcome = r.error == .success || r.observed != nil
                            ? FrameClassifier.classify(requested: plan.frame, before: original, observed: r.observed)
                            : .failed
                        if let o = r.observed {
                            observed = "\(Int(o.minX)),\(Int(o.minY))"
                            visible = o.largestVisiblePiece(on: displays).map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"
                            hidden = Parking.isEffectivelyHidden(o, displays: displays) ? "✅" : "❌"
                        }
                        latency = String(format: "%.0f", r.latencyMs)
                        latencies.append(r.latencyMs)
                        writer?.write(TraceEvent(
                            t: writer?.elapsed ?? 0, kind: .setFrame, pid: handle.pid, app: handle.name, window: w.key,
                            title: w.title, frame: r.observed, requested: plan.frame, outcome: outcome,
                            latencyMs: r.latencyMs, axError: r.error == .success ? nil : r.error.rawValue,
                            detail: "park \(strategy.rawValue) \(plan.corner.rawValue)"
                        ))
                    } catch {
                        observed = "⚠️ \(error)"
                        writer?.write(TraceEvent(
                            t: writer?.elapsed ?? 0, kind: .axTimeout, pid: handle.pid, app: handle.name, window: w.key,
                            requested: plan.frame, detail: "park \(strategy.rawValue): \(error)"
                        ))
                    }

                    // Restore ALWAYS — a timed-out park may still have moved the window (memory/gotchas.md #7).
                    // Wait out a still-busy worker instead of giving up.
                    do {
                        let back = try handle.setFrame(w.element, original, settle: settle, waitIfBusy: 5)
                        let ok = back.observed?.approximatelyEquals(original, tolerance: 4) ?? false
                        restored = ok ? "✅" : "❌ \(back.observed?.description ?? "?")"
                        allRestored = allRestored && ok
                    } catch {
                        restored = "⚠️ \(error)"
                        allRestored = false
                    }
                    stats["\(strategy.rawValue) \(plan.corner.rawValue)", default: []].append(outcome)
                    if hidden == "✅" { hiddenCount["\(strategy.rawValue) \(plan.corner.rawValue)", default: 0] += 1 }
                    rows.append([
                        handle.name, w.title.truncated(28), strategy.rawValue, plan.corner.rawValue,
                        outcome.rawValue, observed, visible, hidden, latency, restored,
                    ])
                }

                if allRestored {
                    var journal = ParkJournal.load(from: LatticePaths.journal)
                    journal.remove(windowKey: w.key)
                    try? journal.save(to: LatticePaths.journal)
                }
            }
        }

        printTable(rows)
        print("")
        for (strategy, outcomes) in stats.sorted(by: { $0.key < $1.key }) {
            let counts = Dictionary(grouping: outcomes, by: \.self).mapValues(\.count)
            let summary = [FrameOutcome.honored, .clamped, .ignored, .failed]
                .compactMap { o in counts[o].map { "\(o.rawValue) \($0)" } }
                .joined(separator: ", ")
            let hiddenN = hiddenCount[strategy] ?? 0
            print("\(strategy.padding(toLength: 22, withPad: " ", startingAt: 0)) \(summary) · effectively hidden \(hiddenN)/\(outcomes.count)")
        }
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            print(String(format: "set-frame latency: median %.1f ms, max %.1f ms", sorted[sorted.count / 2], sorted.last!))
        }
        if let writer { writer.close(); print("Trace: \(writer.url.path)") }
        let left = ParkJournal.load(from: LatticePaths.journal).entries.count
        if left > 0 { print("⚠️ \(left) window(s) still journaled — run `lattice rescue`") }
    }

    // MARK: - rescue

    static func rescue(dryRun: Bool) {
        JournalRestore.run(dryRun: dryRun)

        let displays = Displays.current()
        var moved = 0
        for running in AppHandle.regularApps() {
            let handle = AppHandle(running)
            guard let windows = try? handle.windows() else {
                print("⚠️ \(handle.name): not responding, skipped")
                continue
            }
            for w in windows where w.manageable && !w.minimized {
                guard let f = w.frame, Rescue.isStranded(f, displays: displays),
                      let target = Rescue.rescueFrame(for: f, displays: displays) else { continue }
                print("\(dryRun ? "would move" : "moving") \(handle.name) “\(w.title.truncated(40))” \(f) → \(target)")
                if !dryRun { _ = try? handle.setFrame(w.element, target) }
                moved += 1
            }
        }
        print(moved == 0 ? "No stranded windows." : "\(moved) stranded window(s) \(dryRun ? "found" : "moved on-screen").")
    }

    // MARK: - helpers

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func printTable(_ rows: [[String]]) {
        guard let header = rows.first else { return }
        let widths = header.indices.map { i in rows.map { $0.indices.contains(i) ? $0[i].count : 0 }.max() ?? 0 }
        for row in rows {
            print(row.enumerated().map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  "))
        }
    }
}

/// Restores every journaled window to its original frame. Nonisolated: also runs from the SIGINT handler.
enum JournalRestore {
    static func run(dryRun: Bool) {
        var journal = ParkJournal.load(from: LatticePaths.journal)
        guard !journal.entries.isEmpty else { return }
        print("Park journal: \(journal.entries.count) window(s) to restore")
        for entry in journal.entries {
            guard kill(entry.pid, 0) == 0 else {
                print("  \(entry.app) (pid \(entry.pid)) is gone — dropping entry")
                journal.remove(windowKey: entry.windowKey)
                continue
            }
            let handle = AppHandle(pid: entry.pid, name: entry.app, bundleID: nil)
            guard let windows = try? handle.windows(),
                  let w = windows.first(where: { $0.key == entry.windowKey }) ?? windows.first(where: { $0.title == entry.title })
            else {
                print("  ⚠️ \(entry.app) “\(entry.title)”: window not found, keeping entry")
                continue
            }
            print("  \(dryRun ? "would restore" : "restoring") \(entry.app) “\(entry.title.truncated(40))” → \(entry.original)")
            guard !dryRun else { continue }
            if let r = try? handle.setFrame(w.element, entry.original, waitIfBusy: 5), r.observed?.approximatelyEquals(entry.original, tolerance: 4) == true {
                journal.remove(windowKey: entry.windowKey)
            } else {
                print("    ⚠️ restore not confirmed, keeping entry")
            }
        }
        if !dryRun { try? journal.save(to: LatticePaths.journal) }
    }
}

extension String {
    func truncated(_ n: Int) -> String { count <= n ? self : String(prefix(n - 1)) + "…" }
}
