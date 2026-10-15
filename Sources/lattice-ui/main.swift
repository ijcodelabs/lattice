import AppKit
import LatticeCore

// lattice-ui: the HUD/palette helper. Spawned and supervised by `lattice run`; talks JSON lines on
// stdin (UIRequest) / stdout (UIReply). It never touches the Accessibility API.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, may own key windows (the palette)
let ui = UIController()
ui.start()
app.run()
