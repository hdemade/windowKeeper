import Cocoa
import ApplicationServices

// MARK: - Journal

func wkLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WindowKeeper.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

// MARK: - API privées (chargées dynamiquement, aucune injection, compatibles SIP)

let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

enum Priv {
    private static let skylight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func raw(_ names: [String]) -> UnsafeMutableRawPointer? {
        for name in names {
            if let handle = skylight, let p = dlsym(handle, name) { return p }
            if let p = dlsym(rtldDefault, name) { return p }
        }
        return nil
    }

    typealias MainConnFn = @convention(c) () -> Int32
    typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    typealias SetCompatFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias SetWorkspaceFn = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32
    typealias PerformBridgedFn = @convention(c) (AnyObject) -> Int64
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias AXCreateRemoteFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    static let mainConnection: MainConnFn? =
        raw(["SLSMainConnectionID", "CGSMainConnectionID"]).map { unsafeBitCast($0, to: MainConnFn.self) }
    static let copyManagedDisplaySpaces: CopyDisplaySpacesFn? =
        raw(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"]).map { unsafeBitCast($0, to: CopyDisplaySpacesFn.self) }
    static let copySpacesForWindows: CopySpacesForWindowsFn? =
        raw(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"]).map { unsafeBitCast($0, to: CopySpacesForWindowsFn.self) }
    static let moveWindowsToManagedSpace: MoveWindowsFn? =
        raw(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"]).map { unsafeBitCast($0, to: MoveWindowsFn.self) }
    static let spaceSetCompatID: SetCompatFn? =
        raw(["SLSSpaceSetCompatID"]).map { unsafeBitCast($0, to: SetCompatFn.self) }
    static let setWindowListWorkspace: SetWorkspaceFn? =
        raw(["SLSSetWindowListWorkspace"]).map { unsafeBitCast($0, to: SetWorkspaceFn.self) }
    static let performBridged: PerformBridgedFn? =
        raw(["SLSPerformAsynchronousBridgedWindowManagementOperation"]).map { unsafeBitCast($0, to: PerformBridgedFn.self) }
    static let axGetWindow: AXGetWindowFn? =
        raw(["_AXUIElementGetWindow"]).map { unsafeBitCast($0, to: AXGetWindowFn.self) }
    static let axCreateWithRemoteToken: AXCreateRemoteFn? =
        raw(["_AXUIElementCreateWithRemoteToken"]).map { unsafeBitCast($0, to: AXCreateRemoteFn.self) }

    static let cid: Int32 = mainConnection?() ?? 0
}

// MARK: - Écrans

struct DisplayInfo {
    let id: CGDirectDisplayID
    let uuid: String
    let bounds: CGRect   // coordonnées globales, origine en haut à gauche
}

enum Displays {
    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return (CFUUIDCreateString(nil, cf) as String?) ?? "display-\(id)"
    }

    static func active() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { DisplayInfo(id: $0, uuid: uuid(of: $0), bounds: CGDisplayBounds($0)) }
    }

    /// Identifie une configuration d'écrans (ex. « portable seul », « portable + 2 écrans du bureau »).
    static func configKey(_ displays: [DisplayInfo] = active()) -> String {
        displays.map { $0.uuid }.sorted().joined(separator: "+")
    }

    static func display(containing frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit }
        return displays.max(by: { $0.bounds.intersection(frame).area < $1.bounds.intersection(frame).area })
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Bureaux (Spaces)

struct SpaceInfo {
    let id: UInt64
    let uuid: String
    let displayUUID: String
    let index: Int        // rang du bureau sur son écran (1, 2, 3…), 0 pour un espace plein écran
    let isUser: Bool
    let isCurrent: Bool
}

enum Spaces {
    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        ((dict["id64"] ?? dict["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    static func all() -> [SpaceInfo] {
        guard let copy = Priv.copyManagedDisplaySpaces,
              let displays = copy(Priv.cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: [SpaceInfo] = []
        for display in displays {
            var displayUUID = display["Display Identifier"] as? String ?? ""
            if displayUUID == "Main" { displayUUID = Displays.uuid(of: CGMainDisplayID()) }
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID)
            var index = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(space) else { continue }
                let isUser = ((space["type"] as? NSNumber)?.intValue ?? 0) == 0
                if isUser { index += 1 }
                result.append(SpaceInfo(id: id,
                                        uuid: space["uuid"] as? String ?? "",
                                        displayUUID: displayUUID,
                                        index: isUser ? index : 0,
                                        isUser: isUser,
                                        isCurrent: id == current))
            }
        }
        return result
    }

    static func of(window: CGWindowID) -> [UInt64] {
        guard let copy = Priv.copySpacesForWindows else { return [] }
        let list = [NSNumber(value: window)] as CFArray
        guard let spaces = copy(Priv.cid, 0x7, list)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return spaces.map { $0.uint64Value }
    }
}

// MARK: - Déplacement d'une fenêtre vers un autre bureau

enum SpaceMover {
    enum Method: String, CaseIterable {
        case bridged   // macOS 26 : SLSBridgedMoveWindowsToManagedSpaceOperation
        case direct    // macOS <= 14.4 : SLSMoveWindowsToManagedSpace
        case compat    // macOS 14.5 – 15 : astuce de l'identifiant de compatibilité
    }

    static var preferred: Method?

    static func landed(_ window: CGWindowID, on space: UInt64, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Spaces.of(window: window).contains(space) { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    static func attempt(_ method: Method, _ window: CGWindowID, _ space: UInt64) -> Bool {
        switch method {
        case .bridged: return bridged(window, space)
        case .direct:
            guard let move = Priv.moveWindowsToManagedSpace else { return false }
            move(Priv.cid, [NSNumber(value: window)] as CFArray, space)
            return true
        case .compat:
            guard let setCompat = Priv.spaceSetCompatID, let setWorkspace = Priv.setWindowListWorkspace else { return false }
            let tag: Int32 = 0x7961_6265
            var id = window
            _ = setCompat(Priv.cid, space, tag)
            _ = setWorkspace(Priv.cid, &id, 1, tag)
            _ = setCompat(Priv.cid, space, 0)
            return true
        }
    }

    private static func bridged(_ window: CGWindowID, _ space: UInt64) -> Bool {
        guard let cls: AnyClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let msgSend = dlsym(rtldDefault, "objc_msgSend") else { return false }
        let initSel = NSSelectorFromString("initWithWindows:spaceID:")
        let performSel = NSSelectorFromString("performWithWMBridgeDelegate")
        guard class_respondsToSelector(cls, initSel) else { return false }
        typealias AllocFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        return autoreleasepool { () -> Bool in
            guard let allocated = unsafeBitCast(msgSend, to: AllocFn.self)(cls as AnyObject, NSSelectorFromString("alloc")) else { return false }
            let windows = [NSNumber(value: window)] as NSArray
            // init consomme la référence renvoyée par alloc et renvoie un objet +1.
            guard let operation = unsafeBitCast(msgSend, to: InitFn.self)(allocated.takeUnretainedValue(), initSel, windows, space)?.takeRetainedValue() else { return false }
            if class_respondsToSelector(cls, performSel) {
                unsafeBitCast(msgSend, to: VoidFn.self)(operation, performSel)
                return true
            }
            if let perform = Priv.performBridged {
                _ = perform(operation)
                return true
            }
            return false
        }
    }

    /// Essaie chaque méthode et vérifie auprès du serveur de fenêtres que la fenêtre a bien changé de bureau.
    static func move(_ window: CGWindowID, to space: UInt64) -> Method? {
        var order = Method.allCases
        if let p = preferred { order.removeAll { $0 == p }; order.insert(p, at: 0) }
        for method in order {
            guard attempt(method, window, space) else { continue }
            if landed(window, on: space, within: method == .bridged ? 1.5 : 0.4) {
                preferred = method
                return method
            }
        }
        return nil
    }
}

// MARK: - Accessibilité

enum AX {
    static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let get = Priv.axGetWindow else { return nil }
        var id: CGWindowID = 0
        return get(element, &id) == .success && id != 0 ? id : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        var point = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Taille, position, puis taille : nécessaire quand la fenêtre change d'écran.
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    /// Les fenêtres situées sur un bureau non affiché ne sont pas listées par l'API officielle ;
    /// on les retrouve en essayant les identifiants d'éléments un par un.
    static func bruteForceWindows(pid: pid_t, budget: TimeInterval) -> [AXUIElement] {
        guard let create = Priv.axCreateWithRemoteToken else { return [] }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        var result: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(budget)
        for elementID: UInt64 in 0..<1000 {
            if elementID % 50 == 0 && Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            if let subrole: String = attr(element, kAXSubroleAttribute),
               subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole {
                result.append(element)
            }
        }
        return result
    }
}
