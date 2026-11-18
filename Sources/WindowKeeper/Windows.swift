import Cocoa
import ApplicationServices

// MARK: - Fenêtres vivantes

struct LiveWindow {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let spaces: [UInt64]
    let zIndex: Int
}

/// À n'utiliser que depuis la file de travail (pas de verrou interne).
final class WindowScanner {
    private var cache: [CGWindowID: AXUIElement] = [:]
    private var junk: [CGWindowID: Date] = [:]

    func scan() -> [LiveWindow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates: [pid_t: [CGWindowID]] = [:]
        var zIndex: [CGWindowID: Int] = [:]
        for (order, entry) in info.enumerated() {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            zIndex[id] = order
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict),
               bounds.width >= 100, bounds.height >= 60,
               ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 {
                candidates[pid, default: []].append(id)
            }
        }

        let now = Date()
        junk = junk.filter { now.timeIntervalSince($0.value) < 300 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [LiveWindow] = []
        var alive: Set<CGWindowID> = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
                  app.processIdentifier != ownPID, !app.isTerminated else { continue }
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 1.0)

            var found: [CGWindowID: AXUIElement] = [:]
            let listed: [AXUIElement] = AX.attr(appElement, kAXWindowsAttribute) ?? []
            for element in listed {
                if let id = AX.windowID(element) { found[id] = element }
            }
            // Fenêtres connues du serveur de fenêtres mais absentes de la liste (autres bureaux).
            var missing = (candidates[pid] ?? []).filter { found[$0] == nil && junk[$0] == nil && !Spaces.of(window: $0).isEmpty }
            for id in missing {
                if let cached = cache[id], AX.windowID(cached) == id { found[id] = cached }
            }
            missing.removeAll { found[$0] != nil }
            if !missing.isEmpty {
                for element in AX.bruteForceWindows(pid: pid, budget: 1.5) {
                    if let id = AX.windowID(element), found[id] == nil { found[id] = element }
                }
                for id in missing where found[id] == nil { junk[id] = now }
            }

            for (id, element) in found {
                cache[id] = element
                alive.insert(id)
                guard let subrole: String = AX.attr(element, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole else { continue }
                if let fullScreen: Bool = AX.attr(element, "AXFullScreen"), fullScreen { continue }
                guard let frame = AX.frame(element), frame.width > 1, frame.height > 1 else { continue }
                let title: String = AX.attr(element, kAXTitleAttribute) ?? ""
                result.append(LiveWindow(id: id, pid: pid, bundleID: bundleID,
                                         appName: app.localizedName ?? bundleID,
                                         title: title, frame: frame, element: element,
                                         spaces: Spaces.of(window: id),
                                         zIndex: zIndex[id] ?? Int.max))
            }
        }
        cache = cache.filter { alive.contains($0.key) }
        return result.sorted { $0.zIndex < $1.zIndex }
    }
}

// MARK: - Disposition enregistrée

struct WindowRecord: Codable {
    var windowID: UInt32
    var bundleID: String
    var appName: String
    var title: String
    var frame: CGRect            // coordonnées globales
    var displayUUID: String?     // écran qui contient la fenêtre
    var relativeOrigin: CGPoint? // position par rapport au coin de cet écran
    var spaceUUID: String?
    var spaceDisplayUUID: String?
    var spaceIndex: Int?
}

struct DisplayRecord: Codable {
    var uuid: String
    var name: String
    var bounds: CGRect
}

struct Layout: Codable {
    var configKey: String
    var displayCount: Int
    var savedAt: Date
    var bootID: Int
    var windows: [WindowRecord]
    var displays: [DisplayRecord]?   // absent des sauvegardes de la première version
    var name: String?                // nom choisi par l'utilisateur, absent par défaut

    var title: String {
        if let name = name, !name.isEmpty { return name }
        return defaultTitle
    }

    /// Nom déduit des écrans, utilisé tant que l'utilisateur n'en a pas choisi un.
    var defaultTitle: String {
        guard let displays = displays, !displays.isEmpty else {
            return "\(displayCount) écran\(displayCount > 1 ? "s" : "")"
        }
        return displays.sorted { $0.bounds.minX < $1.bounds.minX }.map { $0.name }.joined(separator: " + ")
    }
}

func displayNames() -> [CGDirectDisplayID: String] {
    let read = { () -> [CGDirectDisplayID: String] in
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

func currentBootID() -> Int {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    return sysctl(&mib, 2, &tv, &size, nil, 0) == 0 ? tv.tv_sec : 0
}

enum Snapshot {
    /// Renvoie nil si la configuration d'écrans a changé pendant la capture.
    static func capture(scanner: WindowScanner) -> Layout? {
        let displays = Displays.active()
        let key = Displays.configKey(displays)
        let spaces = Dictionary(Spaces.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = scanner.scan()
        guard Displays.configKey() == key else { return nil }
        let records = windows.map { w -> WindowRecord in
            let display = Displays.display(containing: w.frame, in: displays)
            // Une fenêtre présente sur tous les bureaux a plusieurs espaces : on ne lui en impose aucun.
            let space = w.spaces.count == 1 ? spaces[w.spaces[0]] : nil
            let userSpace = (space?.isUser ?? false) ? space : nil
            return WindowRecord(windowID: w.id, bundleID: w.bundleID, appName: w.appName, title: w.title,
                                frame: w.frame,
                                displayUUID: display?.uuid,
                                relativeOrigin: display.map { CGPoint(x: w.frame.minX - $0.bounds.minX, y: w.frame.minY - $0.bounds.minY) },
                                spaceUUID: userSpace?.uuid,
                                spaceDisplayUUID: userSpace?.displayUUID,
                                spaceIndex: userSpace?.index)
        }
        let names = displayNames()
        let displayRecords = displays.map { DisplayRecord(uuid: $0.uuid, name: names[$0.id] ?? "Écran", bounds: $0.bounds) }
        return Layout(configKey: key, displayCount: displays.count, savedAt: Date(), bootID: currentBootID(),
                      windows: records, displays: displayRecords)
    }
}

// MARK: - Stockage

/// À n'utiliser que depuis le fil principal.
final class LayoutStore {
    private struct File: Codable {
        var layouts: [String: Layout] = [:]
        var previous: [String: Layout] = [:]
    }

    private var file = File()
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("layouts.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let decoded = try? decoder.decode(File.self, from: data) {
            file = decoded
        }
    }

    var count: Int { file.layouts.count }

    func layout(for key: String) -> Layout? { file.layouts[key] }

    func save(_ layout: Layout) {
        var layout = layout
        if let old = file.layouts[layout.configKey] {
            file.previous[layout.configKey] = old
            // Le nom choisi survit aux sauvegardes successives.
            if layout.name == nil { layout.name = old.name }
        }
        file.layouts[layout.configKey] = layout
        persist()
    }

    /// Un nom vide rétablit le nom déduit des écrans.
    func rename(key: String, to name: String) {
        guard file.layouts[key] != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        file.layouts[key]?.name = value
        file.previous[key]?.name = value
        persist()
    }

    /// Si la dernière sauvegarde date de juste avant un changement d'écrans, elle a pu capturer
    /// des fenêtres déjà déplacées par macOS : on revient à la précédente.
    func rollbackIfRecent(key: String, within seconds: TimeInterval) {
        guard let current = file.layouts[key], Date().timeIntervalSince(current.savedAt) < seconds,
              var previous = file.previous[key] else { return }
        previous.name = current.name
        file.layouts[key] = previous
        persist()
        wkLog("Sauvegarde trop récente écartée pour \(key)")
    }

    var all: [Layout] { file.layouts.values.sorted { $0.savedAt > $1.savedAt } }

    func remove(key: String) {
        file.layouts[key] = nil
        file.previous[key] = nil
        persist()
    }

    func removeAll() {
        file = File()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Restauration

struct RestoreReport {
    var total = 0
    var matched = 0
    var framesSet = 0
    var spacesMoved = 0
    var spaceFailures: [String] = []
    var missingSpaces: [String] = []
    var notFound: [String] = []
    var method: String?

    var summary: String {
        var lines = ["\(matched) fenêtre(s) retrouvée(s) sur \(total) enregistrée(s).",
                     "\(framesSet) repositionnée(s), \(spacesMoved) changée(s) de bureau."]
        if let m = method { lines.append("Méthode de changement de bureau utilisée : \(m).") }
        if !spaceFailures.isEmpty {
            lines.append("")
            lines.append("macOS a refusé le changement de bureau pour :")
            lines += spaceFailures.prefix(15).map { "  • \($0)" }
        }
        if !missingSpaces.isEmpty {
            lines.append("")
            lines.append("Bureau enregistré introuvable (à recréer dans Mission Control) pour :")
            lines += missingSpaces.prefix(15).map { "  • \($0)" }
        }
        if !notFound.isEmpty {
            lines.append("")
            lines.append("Fenêtres enregistrées mais fermées depuis :")
            lines += notFound.prefix(15).map { "  • \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

enum Restorer {
    static func restore(_ layout: Layout, scanner: WindowScanner) -> RestoreReport {
        var report = RestoreReport()
        report.total = layout.windows.count
        let displays = Displays.active()
        let spaces = Spaces.all()
        let live = scanner.scan()

        // 1. Association fenêtre enregistrée -> fenêtre vivante.
        var pairs: [(WindowRecord, LiveWindow)] = []
        var freeLive = live
        var pending = layout.windows
        func take(_ match: (WindowRecord, LiveWindow) -> Bool) {
            var rest: [WindowRecord] = []
            for record in pending {
                if let i = freeLive.firstIndex(where: { match(record, $0) }) {
                    pairs.append((record, freeLive.remove(at: i)))
                } else {
                    rest.append(record)
                }
            }
            pending = rest
        }
        if layout.bootID == currentBootID() {
            take { $0.windowID == $1.id && $0.bundleID == $1.bundleID }
        }
        take { $0.bundleID == $1.bundleID && !$0.title.isEmpty && $0.title == $1.title }
        take { $0.bundleID == $1.bundleID }
        report.matched = pairs.count
        report.notFound = pending.map { label($0.appName, $0.title) }

        // 2. Application.
        for (record, window) in pairs {
            let name = label(record.appName, record.title)

            if record.spaceUUID != nil || record.spaceIndex != nil {
                let target = spaces.first(where: { $0.isUser && !($0.uuid.isEmpty) && $0.uuid == record.spaceUUID })
                    ?? spaces.first(where: { $0.isUser && $0.displayUUID == record.spaceDisplayUUID && $0.index == record.spaceIndex })
                if let target = target {
                    let current = Spaces.of(window: window.id)
                    if current.count == 1, current[0] != target.id {
                        if let method = SpaceMover.move(window.id, to: target.id) {
                            report.spacesMoved += 1
                            report.method = method.rawValue
                        } else {
                            report.spaceFailures.append(name)
                        }
                    }
                } else {
                    report.missingSpaces.append("\(name) (bureau \(record.spaceIndex ?? 0))")
                }
            }

            var targetFrame = record.frame
            if let uuid = record.displayUUID, let rel = record.relativeOrigin,
               let display = displays.first(where: { $0.uuid == uuid }) {
                targetFrame.origin = CGPoint(x: display.bounds.minX + rel.x, y: display.bounds.minY + rel.y)
            }
            let currentFrame = AX.frame(window.element) ?? window.frame
            if !close(currentFrame, targetFrame) {
                AX.setFrame(window.element, targetFrame)
                report.framesSet += 1
            }
        }
        return report
    }

    private static func label(_ app: String, _ title: String) -> String {
        title.isEmpty ? app : "\(app) — \(title.prefix(60))"
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
