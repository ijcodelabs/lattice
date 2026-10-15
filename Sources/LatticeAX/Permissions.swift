import ApplicationServices
import CoreGraphics

public enum Permissions {
    /// Accessibility (AX). `prompt` shows the system dialog that deep-links to System Settings.
    public static func accessibility(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Input Monitoring — required for the CGEventTap hotkey path (milestone 2).
    public static func inputMonitoring(prompt: Bool = false) -> Bool {
        prompt ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
    }
}
