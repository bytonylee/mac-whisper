import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only app; no Dock icon, no main menu activation.
app.setActivationPolicy(.accessory)
app.run()
