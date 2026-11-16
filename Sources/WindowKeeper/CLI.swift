import Cocoa
import ApplicationServices

/// Modes en ligne de commande pour diagnostiquer ce que macOS autorise sur cette machine.
enum CLI {
    static func diagnose() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        print("Accessibilité accordée à ce processus : \(AXIsProcessTrusted())")
        print("Symboles privés :")
        print("  liste des bureaux            : \(Priv.copyManagedDisplaySpaces != nil)")
        print("  bureau d'une fenêtre         : \(Priv.copySpacesForWindows != nil)")
        print("  déplacement « bridged »      : \(NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") != nil)")
        print("  déplacement « direct »       : \(Priv.moveWindowsToManagedSpace != nil)")
        print("  déplacement « compat »       : \(Priv.spaceSetCompatID != nil && Priv.setWindowListWorkspace != nil)")
        print("  identifiant fenêtre AX       : \(Priv.axGetWindow != nil)")
        print("  fenêtres des autres bureaux  : \(Priv.axCreateWithRemoteToken != nil)")
        let displays = Displays.active()
        print("Écrans (\(displays.count)) :")
        for d in displays { print("  \(d.uuid)  \(Int(d.bounds.width))x\(Int(d.bounds.height)) @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))") }
        let spaces = Spaces.all()
        print("Bureaux (\(spaces.count)) :")
        for s in spaces {
            print("  id \(s.id)  écran \(s.displayUUID.prefix(8))  \(s.isUser ? "bureau \(s.index)" : "plein écran")\(s.isCurrent ? "  (affiché)" : "")")
        }
        if AXIsProcessTrusted() {
            let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let windows = WindowScanner().scan()
            print("Fenêtres (\(windows.count)) :")
            for w in windows {
                let where_ = w.spaces.compactMap { byID[$0] }.map { "bureau \($0.index)" }.joined(separator: ",")
                print("  [\(w.id)] \(w.appName) — \(w.title.prefix(40))  \(Int(w.frame.width))x\(Int(w.frame.height)) @ (\(Int(w.frame.minX)),\(Int(w.frame.minY)))  \(where_)")
            }
        } else {
            print("Fenêtres : non listées (autorisation Accessibilité absente pour ce processus)")
        }
    }

    /// Ouvre une petite fenêtre dans un second processus et essaie de la changer de bureau avec chaque méthode.
    static func selfTest() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--helper-window"]
        do { try process.run() } catch {
            print("Impossible de lancer la fenêtre de test : \(error)")
            return 1
        }
        defer { process.terminate() }

        var window: CGWindowID?
        let deadline = Date().addingTimeInterval(8)
        while window == nil && Date() < deadline {
            usleep(100_000)
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            window = info.first(where: {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier
                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }).flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
        guard let wid = window else {
            print("La fenêtre de test n'est pas apparue.")
            return 1
        }
        usleep(500_000)
        let spaces = Spaces.all()
        guard let originID = Spaces.of(window: wid).first, let origin = spaces.first(where: { $0.id == originID }) else {
            print("Impossible de lire le bureau de la fenêtre de test.")
            return 1
        }
        guard let target = spaces.first(where: { $0.isUser && $0.id != origin.id && $0.displayUUID == origin.displayUUID })
                ?? spaces.first(where: { $0.isUser && $0.id != origin.id }) else {
            print("Un seul bureau existe : créez-en un second dans Mission Control pour tester.")
            return 2
        }
        print("Fenêtre de test \(wid) : bureau \(origin.index) -> bureau \(target.index)")
        var working: [String] = []
        for method in SpaceMover.Method.allCases {
            let sent = SpaceMover.attempt(method, wid, target.id)
            let ok = sent && SpaceMover.landed(wid, on: target.id, within: 2)
            var back = false
            if ok {
                _ = SpaceMover.attempt(method, wid, origin.id)
                back = SpaceMover.landed(wid, on: origin.id, within: 2)
                working.append(method.rawValue)
            }
            print("  \(method.rawValue) : \(sent ? (ok ? "OK" : "sans effet") : "indisponible")\(ok ? (back ? ", retour OK" : ", retour ÉCHEC") : "")")
        }
        print(working.isEmpty ? "RÉSULTAT : aucune méthode ne déplace une fenêtre vers un autre bureau sur ce macOS."
                              : "RÉSULTAT : méthode(s) fonctionnelle(s) : \(working.joined(separator: ", "))")
        return working.isEmpty ? 3 : 0
    }

    static func helperWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WindowKeeper — test"
        window.orderFrontRegardless()
        // Sécurité : la fenêtre de test ne survit jamais plus de 30 secondes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
        withExtendedLifetime(window) { app.run() }
    }
}
