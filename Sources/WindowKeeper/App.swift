import Cocoa
import ApplicationServices
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    /// Incrémenté à chaque changement d'état pour rafraîchir la fenêtre.
    @Published var revision = 0
    private var mainWindow: NSWindow?
    private var refreshTimer: Timer?
    private var statusItem: NSStatusItem!
    let store = LayoutStore()
    private let scanner = WindowScanner()
    private let worker = DispatchQueue(label: "windowkeeper.worker", qos: .utility)

    private(set) var currentKey = Displays.configKey()
    private var transitioning = false
    private var forceRestore = false
    private var debounce: Timer?
    private var autoSaveTimer: Timer?
    private(set) var lastReport = "Aucune restauration effectuée pour l'instant."
    private var lastSave: Date?
    private(set) var busy = false

    private let defaults = UserDefaults.standard
    var autoSave: Bool {
        get { defaults.object(forKey: "autoSave") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSave"); revision += 1 }
    }
    var autoRestore: Bool {
        get { defaults.object(forKey: "autoRestore") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoRestore"); revision += 1 }
    }
    var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var trusted: Bool { AXIsProcessTrusted() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "WindowKeeper")
            if button.image == nil { button.title = "WK" }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Demande l'autorisation Accessibilité (nécessaire pour lire et déplacer les fenêtres).
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.autoSaveTick() }
        wkLog("Démarrage, configuration \(currentKey)")

        // Au tout premier lancement (rien de sauvegardé ou autorisation manquante), on montre la fenêtre.
        if !trusted || store.count == 0 { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: Fenêtre principale

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "WindowKeeper"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MainView(model: self))
            window.setContentSize(NSSize(width: 940, height: 620))
            window.center()
            window.setFrameAutosaveName("WindowKeeperMain")
            window.delegate = self
            mainWindow = window
        }
        if refreshTimer == nil {
            // Tient à jour l'état (autorisation, dernière sauvegarde) tant que la fenêtre est visible.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self, self.mainWindow?.isVisible == true else { return }
                self.revision += 1
            }
        }
        // L'icône apparaît dans le Dock tant que la fenêtre est ouverte.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, state: Bool? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            if let state = state { item.state = state ? .on : .off }
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }
        menu.autoenablesItems = false

        add("Ouvrir WindowKeeper…", #selector(showMainWindow))
        menu.addItem(.separator())
        if !trusted {
            add("⚠️ Autorisation Accessibilité manquante", nil)
            add("Ouvrir les réglages Accessibilité…", #selector(openAccessibilitySettings))
            menu.addItem(.separator())
        }
        let displayCount = Displays.active().count
        add("Configuration actuelle : \(displayCount) écran\(displayCount > 1 ? "s" : "")", nil)
        if let layout = store.layout(for: currentKey) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            add("Dernière sauvegarde : \(formatter.string(from: layout.savedAt)) (\(layout.windows.count) fenêtres)", nil)
        } else {
            add("Aucune sauvegarde pour cette configuration", nil)
        }
        add("\(store.count) configuration(s) d'écrans mémorisée(s)", nil)
        menu.addItem(.separator())
        add("Sauvegarder la disposition maintenant", #selector(saveNow), enabled: trusted)
        add("Restaurer la disposition", #selector(restoreNow), enabled: trusted && store.layout(for: currentKey) != nil)
        menu.addItem(.separator())
        add("Sauvegarde automatique (toutes les 30 s)", #selector(toggleAutoSave), state: autoSave)
        add("Restauration automatique au changement d'écrans", #selector(toggleAutoRestore), state: autoRestore)
        add("Lancer à l'ouverture de session", #selector(toggleLoginItem), state: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Dernier rapport de restauration…", #selector(showReport))
        add("Effacer toutes les sauvegardes…", #selector(clearAll))
        menu.addItem(.separator())
        add("Quitter WindowKeeper", #selector(quit))
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleAutoSave() { autoSave.toggle() }
    @objc private func toggleAutoRestore() { autoRestore.toggle() }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Impossible de modifier le lancement à l'ouverture de session", "\(error.localizedDescription)")
        }
        revision += 1
    }

    @objc private func showReport() { alert("Dernier rapport de restauration", lastReport) }

    @objc private func clearAll() {
        let box = NSAlert()
        box.messageText = "Effacer toutes les dispositions sauvegardées ?"
        box.addButton(withTitle: "Effacer")
        box.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        if box.runModal() == .alertFirstButtonReturn { store.removeAll(); revision += 1 }
    }

    func delete(key: String) {
        store.remove(key: key)
        revision += 1
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        let box = NSAlert()
        box.messageText = title
        box.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        box.runModal()
    }

    // MARK: Sauvegarde

    private var screenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func autoSaveTick() {
        guard autoSave, trusted, !transitioning, !busy, !screenLocked else { return }
        save(manual: false)
    }

    @objc func saveNow() { save(manual: true) }

    private func save(manual: Bool) {
        guard !busy else { return }
        busy = true
        worker.async { [self] in
            let layout = Snapshot.capture(scanner: scanner)
            DispatchQueue.main.async { [self] in
                busy = false
                defer { revision += 1 }
                guard let layout = layout, layout.configKey == Displays.configKey() else { return }
                if !manual && (transitioning || layout.configKey != currentKey || layout.windows.isEmpty) { return }
                currentKey = layout.configKey
                store.save(layout)
                lastSave = layout.savedAt
                if manual { wkLog("Sauvegarde manuelle : \(layout.windows.count) fenêtres") }
            }
        }
    }

    // MARK: Restauration

    /// Depuis le menu : restaure puis affiche le rapport.
    @objc private func restoreNow() {
        restoreCurrent { [self] in showReport() }
    }

    /// Restaure la disposition de la configuration d'écrans actuelle.
    func restoreCurrent(completion: @escaping () -> Void = {}) {
        guard !busy, let layout = store.layout(for: currentKey) else { return }
        runRestore(layout, passes: 1, completion: completion)
    }

    private func runRestore(_ layout: Layout, passes: Int, completion: @escaping () -> Void) {
        guard trusted else { completion(); return }
        busy = true
        revision += 1
        worker.async { [self] in
            var report = Restorer.restore(layout, scanner: scanner)
            // Après un branchement, macOS redéplace parfois des fenêtres quelques secondes plus tard.
            for _ in 1..<max(passes, 1) {
                Thread.sleep(forTimeInterval: 3)
                let again = Restorer.restore(layout, scanner: scanner)
                report.framesSet += again.framesSet
                report.spacesMoved += again.spacesMoved
                report.spaceFailures = again.spaceFailures
                report.missingSpaces = again.missingSpaces
                report.notFound = again.notFound
                report.matched = again.matched
                report.method = again.method ?? report.method
            }
            let text = report.summary
            wkLog("Restauration (\(layout.configKey)) : \(text.replacingOccurrences(of: "\n", with: " | "))")
            DispatchQueue.main.async { [self] in
                busy = false
                lastReport = text
                revision += 1
                completion()
            }
        }
    }

    // MARK: Changements d'écrans, veille

    @objc private func screensChanged() {
        if !transitioning {
            // La sauvegarde faite juste avant l'événement peut déjà contenir des fenêtres déplacées par macOS.
            store.rollbackIfRecent(key: currentKey, within: 3)
        }
        scheduleSettle(after: 4)
    }

    @objc private func willSleep() {
        transitioning = true
    }

    @objc private func didWake() {
        forceRestore = true
        scheduleSettle(after: 6)
    }

    private func scheduleSettle(after delay: TimeInterval) {
        transitioning = true
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.settle() }
    }

    private func settle() {
        if busy || screenLocked {
            scheduleSettle(after: 3)
            return
        }
        let key = Displays.configKey()
        let changed = key != currentKey
        let force = forceRestore
        forceRestore = false
        currentKey = key
        wkLog("Écrans stabilisés : \(key) (changement : \(changed), réveil : \(force))")
        revision += 1
        guard (changed || force), autoRestore, let layout = store.layout(for: key) else {
            transitioning = false
            return
        }
        runRestore(layout, passes: 2) { [self] in
            // Si les écrans ont encore changé pendant la restauration, un nouveau cycle est déjà programmé.
            if debounce?.isValid != true { transitioning = false }
        }
    }
}
