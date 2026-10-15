import ApplicationServices
import LatticeCore

/// Sendable wrapper around an AXUIElement. CF types are thread-safe to pass around; we only *call* AX
/// on the owning app's `AXWorker`.
public struct AXElement: @unchecked Sendable, Hashable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    public static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.raw, b.raw) }
    public func hash(into h: inout Hasher) { h.combine(CFHash(raw)) }

    /// Stable-enough key for traces/journals within one process lifetime of the target app.
    public func key(pid: pid_t) -> String { "\(pid):\(String(CFHash(raw), radix: 16))" }

    // MARK: - Attributes

    public func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    public var role: String? { attribute(kAXRoleAttribute) }

    /// False once the window is really gone (closed). A window that is merely not *listed* — e.g. it is on
    /// another macOS Space — is still valid. Call on the app's worker.
    public var exists: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }
    public var subrole: String? { attribute(kAXSubroleAttribute) }
    public var title: String? { attribute(kAXTitleAttribute) }
    public var isMinimized: Bool { attribute(kAXMinimizedAttribute) ?? false }
    public var isFullscreen: Bool { attribute("AXFullScreen") ?? false }

    public var windows: [AXElement] {
        let list: [AXUIElement]? = attribute(kAXWindowsAttribute)
        return (list ?? []).map(AXElement.init)
    }

    public var focusedWindow: AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    /// Standard, non-minimized windows are what a tiler manages. Dialogs/sheets/panels float.
    public var isManageableWindow: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    // MARK: - Frame

    public var frame: Rect? {
        guard let posVal: AXValue = attribute(kAXPositionAttribute),
              let sizeVal: AXValue = attribute(kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &p), AXValueGetValue(sizeVal, .cgSize, &s) else { return nil }
        return Rect(x: p.x, y: p.y, width: s.width, height: s.height)
    }

    /// size → position → size: apps that clamp size to their current screen need the second size set
    /// after the move (memory/gotchas.md #3). Returns the first error, if any.
    @discardableResult
    public func setFrame(_ r: Rect) -> AXError {
        var size = CGSize(width: r.width, height: r.height)
        var pos = CGPoint(x: r.minX, y: r.minY)
        guard let sizeVal = AXValueCreate(.cgSize, &size), let posVal = AXValueCreate(.cgPoint, &pos) else {
            return .failure
        }
        let e1 = AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, sizeVal)
        let e2 = AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, posVal)
        let e3 = AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, sizeVal)
        return [e1, e2, e3].first { $0 != .success } ?? .success
    }

    /// Bring this window to the front of its app (the app itself is activated separately via NSRunningApplication).
    public func raise() {
        AXUIElementSetAttributeValue(raw, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(raw, kAXRaiseAction as CFString)
    }

    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }
}

extension AXError {
    public var name: String {
        switch self {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
