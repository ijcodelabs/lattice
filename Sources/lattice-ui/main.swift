import AppKit
import LatticeCore

// lattice-ui: the HUD/palette helper. Spawned and supervised by `lattice run`; talks JSON lines on
// stdin (UIRequest) / stdout (UIReply). It never touches the Accessibility API.

/// The helper lives in Lattice.app's bundle, so macOS may send *it* the app's Quit (`brew upgrade`,
/// `osascript … to quit`, logout). Pass it on to the main process (SIGTERM = clean shutdown: windows put
/// back, layout saved), then exit — refusing would abort a logout.
final class HelperDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let parent = getppid()
        if parent > 1 { kill(parent, SIGTERM) }
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, may own key windows (the palette)
let ui = UIController()
ui.start()
app.run()
