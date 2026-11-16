import Cocoa

let arguments = CommandLine.arguments

if arguments.contains("--helper-window") {
    CLI.helperWindow()
    exit(0)
}

// AppKit doit être chargé pour que le serveur de fenêtres accepte les opérations de déplacement.
let app = NSApplication.shared

if arguments.contains("--diagnose") {
    CLI.diagnose()
    exit(0)
}
if arguments.contains("--selftest") {
    exit(CLI.selfTest())
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
