import AppKit
import LatticeCore

/// Global keyboard hook via a CGEventTap on the main run loop.
///
/// Every key-down is turned into a `KeyChord` (layout-aware) and handed to `route`, which decides
/// synchronously whether to swallow it (the `KeyRouter` does the thinking). The callback must stay fast;
/// commands are executed asynchronously by the router's owner. macOS disables a slow tap
/// (`tapDisabledByTimeout`); we re-enable it immediately.
@MainActor
public final class HotkeyTap {
    /// Return true to swallow the key.
    public typealias Route = @MainActor (KeyChord) -> Bool

    private let route: Route
    /// Left mouse button down/up (never swallowed): `down`, pointer in AX coordinates, modifiers held.
    public var onMouse: (@MainActor (_ down: Bool, _ point: Point, _ mods: KeyChord.Modifiers) -> Void)?
    private var names: [UInt16: String] = KeyCodes.names()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    public private(set) var reenableCount = 0

    /// `LATTICE_DEBUG_KEYS=1` logs every key the tap sees.
    static let debug = ProcessInfo.processInfo.environment["LATTICE_DEBUG_KEYS"] != nil

    public init(route: @escaping Route) { self.route = route }

    /// Rebuild the key-code → name table (keyboard layout changed).
    public func refreshLayout() { names = KeyCodes.names() }

    /// Human-readable problems with these bindings on the current layout.
    public static func problems(_ bindings: [Binding]) -> [String] {
        let layout = KeyCodes.currentLayoutMap()
        return bindings.compactMap { b in
            guard let r = KeyCodes.resolve(b.chord.key, layout: layout) else {
                return "\(b.chord): key '\(b.chord.key)' has no key code — binding ignored"
            }
            return r.fallback ? "\(b.chord): '\(b.chord.key)' isn't on your layout unshifted — using its US position" : nil
        }
    }

    public var isInstalled: Bool { tap != nil }

    static func modifiers(_ f: CGEventFlags) -> KeyChord.Modifiers {
        var mods: KeyChord.Modifiers = []
        if f.contains(.maskCommand) { mods.insert(.cmd) }
        if f.contains(.maskControl) { mods.insert(.ctrl) }
        if f.contains(.maskAlternate) { mods.insert(.alt) }
        if f.contains(.maskShift) { mods.insert(.shift) }
        return mods
    }

    /// Install the tap. Needs Accessibility. Returns false if macOS refused.
    public func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: latticeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Called on the main thread by the tap. Returns true when the event was consumed.
    fileprivate func handle(type: CGEventType, code: UInt16, flags f: CGEventFlags, location: CGPoint) -> Bool {
        if type == .leftMouseDown || type == .leftMouseUp {
            onMouse?(type == .leftMouseDown, Point(x: location.x, y: location.y), Self.modifiers(f))
            return false   // mouse events always pass through
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reenableCount += 1
            return false
        }
        guard type == .keyDown, let key = names[code] else { return false }
        let chord = KeyChord(modifiers: Self.modifiers(f), key: key)
        let consumed = route(chord)
        if Self.debug { print("[tap] \(chord) code=\(code) → \(consumed ? "swallowed" : "passed")") }
        return consumed
    }
}

private func latticeTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run-loop source lives on the main run loop, so we are on the main thread.
    // Only plain values cross into the main-actor call (CGEvent isn't Sendable).
    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let location = event.location
    let consumed = MainActor.assumeIsolated { tap.handle(type: type, code: code, flags: flags, location: location) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
