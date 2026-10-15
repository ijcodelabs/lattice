import Foundation
import LatticeCore

/// Spawns and supervises the `lattice-ui` helper; JSON lines over its stdin/stdout.
/// If the helper dies it is restarted (bounded), and the current HUD is re-sent. Window management
/// never waits on it — a missing UI just means no pop-ups.
@MainActor
final class UIBridge {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts: [Date] = []
    private var stopping = false
    private var lastHUD: HUDModel?
    private let onReply: @MainActor (UIReply) -> Void
    private let log: @MainActor (String) -> Void

    init(onReply: @escaping @MainActor (UIReply) -> Void, log: @escaping @MainActor (String) -> Void) {
        self.onReply = onReply
        self.log = log
    }

    /// `lattice-ui` lives next to the `lattice` binary.
    static var helperURL: URL {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return me.deletingLastPathComponent().appendingPathComponent("lattice-ui")
    }

    func start() {
        let url = Self.helperURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            log("⚠️ UI helper not found at \(url.path) — running without HUD/palette")
            return
        }
        let p = Process()
        p.executableURL = url
        let toUI = Pipe(), fromUI = Pipe()
        p.standardInput = toUI
        p.standardOutput = fromUI
        p.standardError = FileHandle.standardError   // helper logs land in our log
        fromUI.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(chunk) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.died(status: status) } }
        }
        do { try p.run() } catch {
            log("⚠️ UI helper failed to start: \(error)")
            return
        }
        process = p
        input = toUI.fileHandleForWriting
    }

    func send(_ request: UIRequest) {
        if case let .hud(model) = request { lastHUD = model }
        guard let input, var data = try? JSONEncoder().encode(request) else { return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { log("⚠️ UI helper write failed: \(error)") }
    }

    func stop() {
        stopping = true
        send(.quit)
        process?.terminate()
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let reply = try? JSONDecoder().decode(UIReply.self, from: line) { onReply(reply) }
        }
    }

    private func died(status: Int32) {
        process = nil
        input = nil
        guard !stopping else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard restarts.count <= 5 else {
            log("✗ UI helper keeps dying (status \(status)) — giving up; window management continues without HUD/palette")
            return
        }
        log("⚠️ UI helper exited (status \(status)) — restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.start()
                if let hud = self.lastHUD { self.send(.hud(hud)) }
            }
        }
    }
}
