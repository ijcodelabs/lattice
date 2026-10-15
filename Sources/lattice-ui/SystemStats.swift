import Darwin
import Foundation
import IOKit.ps

/// CPU, memory and battery for the bar — public APIs only, sampled on timers, published to SwiftUI.
@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var cpu: Double = 0          // 0–1
    @Published private(set) var memory: Double = 0       // 0–1 (app + wired + compressed)
    @Published private(set) var battery: Battery?

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var onAC: Bool
    }

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var timers: [Timer] = []

    func start() {
        guard timers.isEmpty else { return }
        sample(); sampleBattery()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleBattery() }
        })
    }

    private func sample() {
        // CPU: delta of host-wide tick counters since the last sample.
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r1 = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if r1 == KERN_SUCCESS {
            let t = load.cpu_ticks
            let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
            let busy = user + system + nice, total = busy + idle
            if let last = lastTicks, total > last.total {
                cpu = Double(busy - last.busy) / Double(total - last.total)
            }
            lastTicks = (busy, total)
        }

        // Memory: like Activity Monitor's "Memory Used" (app + wired + compressed).
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if r2 == KERN_SUCCESS {
            let page = Double(getpagesize())
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            let used = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            memory = min(1, max(0, used / Double(ProcessInfo.processInfo.physicalMemory)))
        }
    }

    private func sampleBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { battery = nil; return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            battery = Battery(percent: cap * 100 / max,
                              charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                              onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            return
        }
        battery = nil
    }
}

/// One script widget: runs `/bin/sh -c command` every `interval` seconds off the main thread,
/// with a 5 s timeout, and keeps the last good output.
@MainActor
final class ScriptRunner: ObservableObject {
    struct Output: Equatable {
        var text: String
        var color: String?
        var icon: String?
    }

    @Published private(set) var output = Output(text: "…")
    let command: String
    let interval: Double
    private var timer: Timer?
    private var running = false

    init(command: String, interval: Double) {
        self.command = command
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        run()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func run() {
        guard !running else { return }   // never stack runs of a slow script
        running = true
        let command = self.command
        DispatchQueue.global(qos: .utility).async {
            let result = ScriptRunner.execute(command)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running = false
                    if let result { self.output = result }
                }
            }
        }
    }

    nonisolated static func execute(_ command: String) -> Output? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Output(text: "⚠︎ \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return Output(text: "⚠︎ timeout") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return Output(text: json["text"] as? String ?? "", color: json["color"] as? String, icon: json["icon"] as? String)
        }
        return Output(text: text.components(separatedBy: "\n").first ?? "")
    }
}
